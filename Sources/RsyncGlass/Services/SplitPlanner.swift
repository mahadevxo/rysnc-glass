import Foundation

/// A batch of items one rsync process transfers. Streams pull chunks from a
/// shared queue as they free up, rather than each being handed a fixed share
/// up front.
struct WorkChunk {
    let itemNames: [String]
    let totalKB: Int
    /// Estimated work (see SplitPlanner.cost).
    let cost: Int
}

enum SplitPlanner {
    /// What one directory entry costs in transfer time, expressed as the
    /// number of KB that takes about as long to move.
    ///
    /// Balancing purely on bytes made streams finish at wildly different
    /// times: rsync spends a per-entry cost on stat calls and protocol round
    /// trips regardless of file size, so a bucket holding 100k small files
    /// takes far longer than an equal-sized bucket holding a handful of large
    /// ones. Over SSH rsync sustains on the order of a thousand small files a
    /// second, against tens of MB/s of bulk throughput, which puts one entry
    /// in the same ballpark as this many KB. It's a heuristic — being roughly
    /// right about the shape beats being exactly right about bytes.
    static let perEntryCostKB = 128

    static func cost(of item: SizedItem) -> Int {
        item.sizeKB + item.entryCount * perEntryCostKB
    }

    /// Items costing more than 1/chunksPerStream of a stream's share get
    /// opened up into their children (see refine), so there's enough small
    /// work to deal out. A fixed up-front split relies on the cost estimate
    /// being right, and whenever it's off one stream finishes long after the
    /// rest; pulling chunks from a queue as streams free up absorbs that, but
    /// only if the work comes in pieces.
    static let chunksPerStream = 8

    /// The smallest chunk, as a fraction of one stream's share. Each chunk is
    /// its own rsync process and SSH handshake, so chunks can't be tiny, but
    /// the last ones handed out decide how far apart the streams finish.
    static let finestChunksPerStream = 32

    /// How many rounds of descent to allow. Each round is one more scan (a
    /// single du walk per directory being opened up), so this trades
    /// indexing time for how finely a deep tree can be divided.
    static let maxRefineRounds = 4

    /// Every name in a chunk becomes an rsync command-line argument, so cap
    /// how many and how long, to stay well clear of ARG_MAX.
    static let maxNamesPerChunk = 1000
    static let maxNameBytesPerChunk = 128 * 1024

    /// The cost above which an item is worth opening up into its children.
    static func chunkTarget(totalCost: Int, streamCount: Int) -> Int {
        max(totalCost / (max(streamCount, 1) * chunksPerStream), 1)
    }

    /// Splits items that are bigger than one chunk into their children, so a
    /// single dominant directory doesn't pin one stream while the others idle.
    /// Chunks can only be built out of whole items, so without this the best
    /// possible split of "one 500GB folder plus scraps" is still one stream
    /// doing essentially all the work.
    ///
    /// `expand` returns the direct children of the given paths, named relative
    /// to the same root (`photos/2019`). It's injected so this stays testable
    /// without a filesystem, and so a failed scan can just fall back to the
    /// items we already have.
    static func refine(
        items: [SizedItem],
        streamCount: Int,
        expand: ([String]) async -> [SizedItem]
    ) async -> [SizedItem] {
        guard streamCount > 1, items.count > 0 else { return items }
        var items = items

        for _ in 0..<maxRefineRounds {
            // An item bigger than a chunk can't be dealt out evenly, and one
            // that lands last is a stream still working after the rest are done.
            let target = chunkTarget(totalCost: items.reduce(0) { $0 + cost(of: $1) }, streamCount: streamCount)
            let oversized = items.filter { cost(of: $0) > target && $0.entryCount > 1 }
            guard !oversized.isEmpty else { break }

            let children = await expand(oversized.map { $0.name })
            guard !children.isEmpty else { break }

            // Group children under the parent they came from, longest prefix
            // first so nested parents don't steal each other's children.
            let parentsByDepth = oversized.map { $0.name }.sorted { $0.count > $1.count }
            var childrenByParent: [String: [SizedItem]] = [:]
            for child in children {
                guard let parent = parentsByDepth.first(where: { child.name.hasPrefix($0 + "/") }) else { continue }
                childrenByParent[parent, default: []].append(child)
            }

            var next: [SizedItem] = []
            var didExpand = false
            for item in items {
                let kids = childrenByParent[item.name] ?? []
                // A lone child is the same work one level deeper, so it buys
                // nothing on its own — but it may itself be expandable next
                // round, so keep descending rather than stopping here.
                if kids.isEmpty {
                    next.append(item)
                } else {
                    next.append(contentsOf: kids)
                    didExpand = true
                }
            }
            guard didExpand else { break }
            items = next
        }
        return items
    }

    /// Packs items into chunks, handed out costliest first.
    ///
    /// - shrinking: true sizes each chunk at half of what's left per stream,
    ///   down to the finest size, so chunks start big (few processes, few
    ///   handshakes) and get smaller as the queue drains. A stream that picks
    ///   up the last chunk then isn't left working long after the rest: in
    ///   simulation with estimates off by up to 3× either way, streams finish
    ///   within ~1.5% of each other against ~7% for equal-sized chunks, with
    ///   the same number of processes. false makes every chunk the finest
    ///   size — the relay wants that, since a chunk's size is how much of it
    ///   sits in local staging at once.
    ///
    /// Items are grouped in name order to keep siblings in the same process,
    /// and an item bigger than the target — a large file can't be split —
    /// becomes a chunk of its own.
    static func chunks(items: [SizedItem], streamCount: Int, shrinking: Bool = true) -> [WorkChunk] {
        let streams = max(streamCount, 1)
        let total = items.reduce(0) { $0 + cost(of: $1) }
        let finest = max(total / (streams * finestChunksPerStream), 1)
        var remaining = total
        func target() -> Int {
            shrinking ? max(remaining / (streams * 2), finest) : finest
        }

        var result: [WorkChunk] = []
        var names: [String] = []
        var nameBytes = 0
        var totalKB = 0
        var chunkCost = 0
        var currentTarget = target()

        func emit(_ chunk: WorkChunk, cost: Int) {
            result.append(chunk)
            remaining -= cost
            currentTarget = target()
        }

        func flush() {
            guard !names.isEmpty else { return }
            emit(WorkChunk(itemNames: names, totalKB: totalKB, cost: max(chunkCost, 1)), cost: chunkCost)
            names = []
            nameBytes = 0
            totalKB = 0
            chunkCost = 0
        }

        for item in items.sorted(by: { $0.name < $1.name }) {
            let itemCost = cost(of: item)
            if itemCost >= currentTarget {
                emit(WorkChunk(itemNames: [item.name], totalKB: item.sizeKB, cost: max(itemCost, 1)), cost: itemCost)
                continue
            }
            let bytes = item.name.utf8.count + 1
            if chunkCost + itemCost > currentTarget || names.count >= maxNamesPerChunk || nameBytes + bytes > maxNameBytesPerChunk {
                flush()
            }
            names.append(item.name)
            nameBytes += bytes
            totalKB += item.sizeKB
            chunkCost += itemCost
        }
        flush()
        return result.sorted { $0.cost > $1.cost }
    }
}

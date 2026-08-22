import Foundation

struct StreamPlan {
    let itemNames: [String]
    let totalKB: Int
    /// Estimated work (see SplitPlanner.cost) — what the buckets are balanced
    /// on, and what weights each stream's contribution to overall progress.
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

    /// How many rounds of descent to allow. Each round is another directory
    /// scan, so this trades indexing time for balance. Two rounds reaches
    /// grandchildren, which covers the shapes that actually cause trouble
    /// (one dominant folder, or one dominant folder-of-folders).
    static let maxRefineRounds = 2

    /// Refuse to descend into a directory with more children than this. Every
    /// item becomes an argument on an rsync command line, and splitting a
    /// directory of 50k entries into 50k arguments would blow past ARG_MAX
    /// for no benefit — such a directory is already spread over its siblings.
    static let maxChildrenToExpand = 512

    /// Splits items that are too big for one stream into their children, so a
    /// single dominant directory doesn't pin one stream while the others idle.
    /// Balancing can only move whole items between streams, so without this
    /// the best possible split of "one 500GB folder plus scraps" is still one
    /// stream doing essentially all the work.
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
            // A stream can't finish sooner than its single costliest item, so
            // anything above an even share is what's holding the job back.
            let fairShare = items.reduce(0) { $0 + cost(of: $1) } / streamCount
            let oversized = items.filter { cost(of: $0) > fairShare && $0.entryCount > 1 }
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
                if kids.isEmpty || kids.count > maxChildrenToExpand {
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

    /// Greedily balances items across `streamCount` buckets by estimated work
    /// (costliest first into the currently-lightest bucket), so each parallel
    /// rsync process should take roughly as long as its siblings.
    static func plan(items: [SizedItem], streamCount: Int) -> [StreamPlan] {
        let count = max(1, streamCount)
        var buckets = Array(repeating: (names: [String](), totalKB: 0, cost: 0), count: count)
        let sorted = items.sorted { cost(of: $0) > cost(of: $1) }

        for item in sorted {
            let lightestIndex = buckets.indices.min { buckets[$0].cost < buckets[$1].cost }!
            buckets[lightestIndex].names.append(item.name)
            buckets[lightestIndex].totalKB += item.sizeKB
            buckets[lightestIndex].cost += cost(of: item)
        }

        return buckets
            .filter { !$0.names.isEmpty }
            .map { StreamPlan(itemNames: $0.names, totalKB: max($0.totalKB, 1), cost: max($0.cost, 1)) }
    }
}

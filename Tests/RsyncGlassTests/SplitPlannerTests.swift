import XCTest
@testable import RsyncGlass

final class SplitPlannerTests: XCTestCase {
    func testSmallItemsShareChunksThatShrinkAsTheQueueDrains() {
        let items = (0..<2000).map { SizedItem(name: String(format: "f%04d", $0), sizeKB: 10) }
        let chunks = SplitPlanner.chunks(items: items, streamCount: 4)
        let finest = items.reduce(0) { $0 + SplitPlanner.cost(of: $1) } / (4 * SplitPlanner.finestChunksPerStream)

        XCTAssertGreaterThanOrEqual(chunks.count, 4 * 4, "enough chunks that streams can even each other out")
        XCTAssertLessThan(chunks.count, items.count, "small items should share chunks, not each pay for their own process")
        XCTAssertGreaterThan(chunks.first!.cost, 4 * chunks.last!.cost, "early chunks big, late ones small")
        XCTAssertLessThanOrEqual(chunks.last!.cost, finest + SplitPlanner.cost(of: items[0]))
    }

    /// The relay's chunks all stay at the finest size, since each one sits
    /// in local staging until it's uploaded.
    func testNonShrinkingChunksAllStayAtTheFinestSize() {
        let items = (0..<2000).map { SizedItem(name: String(format: "f%04d", $0), sizeKB: 10) }
        let chunks = SplitPlanner.chunks(items: items, streamCount: 4, shrinking: false)
        let finest = items.reduce(0) { $0 + SplitPlanner.cost(of: $1) } / (4 * SplitPlanner.finestChunksPerStream)
        XCTAssertTrue(chunks.allSatisfy { $0.cost <= finest })
    }

    /// A file can't be split, so one bigger than a chunk has to travel alone.
    func testItemBiggerThanTheTargetBecomesItsOwnChunk() {
        let items = [SizedItem(name: "movie.mkv", sizeKB: 5_000_000)] + (0..<50).map { SizedItem(name: "s\($0)", sizeKB: 100) }
        let chunks = SplitPlanner.chunks(items: items, streamCount: 4)
        let movie = chunks.first { $0.itemNames.contains("movie.mkv") }!
        XCTAssertEqual(movie.itemNames, ["movie.mkv"])
    }

    /// The last chunks handed out decide how far apart the streams finish,
    /// so the big ones have to go first.
    func testChunksAreHandedOutLargestFirst() {
        let items = (1...40).map { SizedItem(name: "d\($0)", sizeKB: $0 * 1000, entryCount: $0) }
        let costs = SplitPlanner.chunks(items: items, streamCount: 4).map { $0.cost }
        XCTAssertEqual(costs, costs.sorted(by: >))
    }

    func testEmptyItemsProduceNoChunks() {
        XCTAssertTrue(SplitPlanner.chunks(items: [], streamCount: 4).isEmpty)
    }

    /// Every name is an argument on an rsync command line.
    func testChunkNameCountIsCappedToStayUnderArgMax() {
        let items = (0..<20_000).map { SizedItem(name: "tiny\($0)", sizeKB: 0) }
        let chunks = SplitPlanner.chunks(items: items, streamCount: 1)
        XCTAssertTrue(chunks.allSatisfy { $0.itemNames.count <= SplitPlanner.maxNamesPerChunk })
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.itemNames.count }, items.count)
    }

    /// The reason balancing looks at entry counts at all: two items of equal
    /// size are not equal work if one is a single file and the other is tens
    /// of thousands of them.
    func testItemWithManyFilesOutweighsSameSizedItemWithOne() {
        let dense = SizedItem(name: "dense", sizeKB: 1000, entryCount: 10_000)
        let sparse = SizedItem(name: "sparse", sizeKB: 1000, entryCount: 1)
        XCTAssertGreaterThan(SplitPlanner.cost(of: dense), SplitPlanner.cost(of: sparse))
    }

    func testChunkCostSumsOverItsItemsAndTotalKBStaysARealByteCount() {
        let items = [
            SizedItem(name: "a", sizeKB: 100, entryCount: 3),
            SizedItem(name: "b", sizeKB: 50, entryCount: 2),
        ]
        let chunks = SplitPlanner.chunks(items: items, streamCount: 1)
        let expected = (100 + 3 * SplitPlanner.perEntryCostKB) + (50 + 2 * SplitPlanner.perEntryCostKB)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.cost }, expected)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.totalKB }, 150)
    }

    /// What the queue is for. The cost estimate is a heuristic, so here each
    /// item's real duration is its estimate times a random factor anywhere
    /// from 0.3× to 3×. A fixed up-front split can't react to that; streams
    /// pulling the next chunk as they free up still finish close together.
    func testStreamsPullingFromTheQueueFinishTogetherDespiteBadEstimates() {
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let items = (0..<300).map { SizedItem(name: String(format: "item%03d", $0), sizeKB: Int(random() * 50_000), entryCount: 1 + Int(random() * 400)) }
        var actualFactor: [String: Double] = [:]
        for item in items { actualFactor[item.name] = 0.3 + random() * 2.7 }

        let streamCount = 4
        let queue = ChunkQueue(SplitPlanner.chunks(items: items, streamCount: streamCount))
        var finishTimes = Array(repeating: 0.0, count: streamCount)
        // The stream that frees up first takes the next chunk.
        while let (_, chunk) = queue.take() {
            let next = finishTimes.indices.min { finishTimes[$0] < finishTimes[$1] }!
            let names = Set(chunk.itemNames)
            finishTimes[next] += items.filter { names.contains($0.name) }
                .reduce(0.0) { $0 + Double(SplitPlanner.cost(of: $1)) * actualFactor[$1.name]! }
        }

        let spread = (finishTimes.max()! - finishTimes.min()!) / finishTimes.max()!
        XCTAssertLessThan(spread, 0.05, "streams should finish within ~5% of each other, got \(finishTimes)")
    }

    // MARK: - Refining oversized items into their children

    /// Balancing can only move whole items between streams, so one dominant
    /// directory pins a stream no matter how good the bin-packing is. This is
    /// the case deep splitting exists for.
    func testDominantDirectoryIsSplitIntoItsChildren() async {
        let items = [
            SizedItem(name: "huge", sizeKB: 900_000, entryCount: 4),
            SizedItem(name: "small", sizeKB: 1_000, entryCount: 1),
        ]
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { parents in
            XCTAssertEqual(parents, ["huge"])
            return (1...4).map { SizedItem(name: "huge/part\($0)", sizeKB: 225_000, entryCount: 1) }
        }
        XCTAssertEqual(Set(refined.map { $0.name }),
                       ["huge/part1", "huge/part2", "huge/part3", "huge/part4", "small"])

        // And there should now be enough chunks to keep all four streams busy.
        XCTAssertGreaterThanOrEqual(SplitPlanner.chunks(items: refined, streamCount: 4).count, 4)
    }

    func testItemsAlreadySmallerThanAChunkAreLeftAloneWithoutScanning() async {
        let items = (1...(4 * SplitPlanner.chunksPerStream)).map { SizedItem(name: "item\($0)", sizeKB: 1000, entryCount: 10) }
        var expandCalled = false
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { _ in
            expandCalled = true
            return []
        }
        XCTAssertFalse(expandCalled, "nothing exceeds a chunk, so no extra directory scan should run")
        XCTAssertEqual(refined.count, 4 * SplitPlanner.chunksPerStream)
    }

    /// A flat folder of thousands of files (a dataset, a maildir) is exactly
    /// what pins one stream when it's left whole. Chunks cap how many names
    /// go on one command line, so there's no longer a reason to leave it.
    func testDirectoryWithThousandsOfChildrenIsStillSplit() async {
        let items = [
            SizedItem(name: "dataset", sizeKB: 900_000, entryCount: 5001),
            SizedItem(name: "small", sizeKB: 1_000, entryCount: 1),
        ]
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { parents in
            guard parents == ["dataset"] else { return [] }
            return (1...5000).map { SizedItem(name: "dataset/img\($0).jpg", sizeKB: 180, entryCount: 1) }
        }
        XCTAssertEqual(refined.count, 5001)
        let chunks = SplitPlanner.chunks(items: refined, streamCount: 4)
        XCTAssertGreaterThanOrEqual(chunks.count, 4 * 4)
    }

    func testSingleFileItemIsNeverDescendedInto() async {
        let items = [
            SizedItem(name: "movie.mkv", sizeKB: 900_000, entryCount: 1),
            SizedItem(name: "small", sizeKB: 10, entryCount: 1),
        ]
        var expandCalled = false
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { _ in
            expandCalled = true
            return []
        }
        XCTAssertFalse(expandCalled, "a one-entry item is a file — there's nothing inside it to split")
        XCTAssertEqual(refined.count, 2)
    }

    func testFailedChildScanFallsBackToTheItemsWeAlreadyHave() async {
        let items = [
            SizedItem(name: "huge", sizeKB: 900_000, entryCount: 50),
            SizedItem(name: "small", sizeKB: 10, entryCount: 1),
        ]
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { _ in [] }
        XCTAssertEqual(Set(refined.map { $0.name }), ["huge", "small"],
                       "a worse split beats a failed transfer")
    }

    /// Two rounds should reach grandchildren, for a source that's one folder
    /// containing one enormous folder.
    func testRefinementDescendsMoreThanOneLevelWhenStillUnbalanced() async {
        let items = [SizedItem(name: "a", sizeKB: 800_000, entryCount: 100)]
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { parents in
            if parents == ["a"] {
                return [SizedItem(name: "a/b", sizeKB: 800_000, entryCount: 99)]
            }
            return (1...4).map { SizedItem(name: "a/b/c\($0)", sizeKB: 200_000, entryCount: 24) }
        }
        XCTAssertEqual(Set(refined.map { $0.name }), ["a/b/c1", "a/b/c2", "a/b/c3", "a/b/c4"])
    }

    func testAllItemsAccountedForNoneDroppedOrDuplicated() {
        let items = (0..<37).map { SizedItem(name: "item\($0)", sizeKB: Int.random(in: 1...5000)) }
        let allNames = SplitPlanner.chunks(items: items, streamCount: 5).flatMap { $0.itemNames }
        XCTAssertEqual(allNames.count, items.count)
        XCTAssertEqual(Set(allNames), Set(items.map { $0.name }))
    }
}

import XCTest
@testable import RsyncGlass

final class SplitPlannerTests: XCTestCase {
    func testEvenlySizedItemsSplitOnePerStream() {
        let items = [
            SizedItem(name: "a", sizeKB: 100),
            SizedItem(name: "b", sizeKB: 100),
            SizedItem(name: "c", sizeKB: 100),
        ]
        let plans = SplitPlanner.plan(items: items, streamCount: 3)
        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(Set(plans.map { $0.totalKB }), [100])
        XCTAssertEqual(Set(plans.flatMap { $0.itemNames }), ["a", "b", "c"])
    }

    /// This is the core correctness property behind "parallel streams": a big
    /// item shouldn't get stuck alone on one stream while many small items
    /// pile onto another, leaving streams wildly unbalanced.
    func testSkewedSizesStayBalancedAcrossStreams() {
        let items = [
            SizedItem(name: "huge", sizeKB: 10_000),
            SizedItem(name: "small1", sizeKB: 500),
            SizedItem(name: "small2", sizeKB: 500),
            SizedItem(name: "small3", sizeKB: 500),
            SizedItem(name: "small4", sizeKB: 500),
            SizedItem(name: "small5", sizeKB: 500),
        ]
        let plans = SplitPlanner.plan(items: items, streamCount: 2)
        XCTAssertEqual(plans.count, 2)

        let hugeStream = plans.first { $0.itemNames.contains("huge") }!
        let otherStream = plans.first { !$0.itemNames.contains("huge") }!
        // The 5 small items (2500KB total) should all pile onto the stream
        // that doesn't have the huge item, keeping the two streams close.
        XCTAssertEqual(otherStream.totalKB, 2500)
        XCTAssertEqual(hugeStream.totalKB, 10_000)
        XCTAssertEqual(otherStream.itemNames.count, 5)
    }

    func testMoreStreamsThanItemsProducesOneBucketPerItemNoEmptyBuckets() {
        let items = [SizedItem(name: "only", sizeKB: 42)]
        let plans = SplitPlanner.plan(items: items, streamCount: 8)
        XCTAssertEqual(plans.count, 1, "empty buckets should be filtered out")
        XCTAssertEqual(plans[0].itemNames, ["only"])
    }

    func testEmptyItemsProducesNoPlans() {
        XCTAssertEqual(SplitPlanner.plan(items: [], streamCount: 4).count, 0)
    }

    func testStreamCountBelowOneClampedToOne() {
        let items = [SizedItem(name: "a", sizeKB: 10), SizedItem(name: "b", sizeKB: 20)]
        let plans = SplitPlanner.plan(items: items, streamCount: 0)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].totalKB, 30)
    }

    func testZeroByteItemsStillGetAtLeastOneKBWeight() {
        let items = [SizedItem(name: "empty", sizeKB: 0)]
        let plans = SplitPlanner.plan(items: items, streamCount: 1)
        XCTAssertEqual(plans[0].totalKB, 1, "totalKB is floored at 1 so workShare math never divides by zero")
    }

    /// The reason balancing looks at entry counts at all: two items of equal
    /// size are not equal work if one is a single file and the other is tens
    /// of thousands of them.
    func testItemWithManyFilesOutweighsSameSizedItemWithOne() {
        let dense = SizedItem(name: "dense", sizeKB: 1000, entryCount: 10_000)
        let sparse = SizedItem(name: "sparse", sizeKB: 1000, entryCount: 1)
        XCTAssertGreaterThan(SplitPlanner.cost(of: dense), SplitPlanner.cost(of: sparse))
    }

    /// The case that motivated weighing entries at all. By bytes these split
    /// evenly as [big1 + photos] / [big2] — but that first stream also has to
    /// grind through 20k files, so it finishes long after the second. Weighing
    /// entries puts the dense tree on a stream of its own instead.
    func testFileHeavyTreeIsNotPiledOntoAStreamThatLooksLightByBytesAlone() {
        let items = [
            SizedItem(name: "big1.iso", sizeKB: 1_500_000, entryCount: 1),
            SizedItem(name: "big2.iso", sizeKB: 1_500_000, entryCount: 1),
            SizedItem(name: "photos", sizeKB: 100_000, entryCount: 20_000),
        ]
        let plans = SplitPlanner.plan(items: items, streamCount: 2)
        XCTAssertEqual(plans.count, 2)

        let photosStream = plans.first { $0.itemNames.contains("photos") }!
        XCTAssertEqual(photosStream.itemNames, ["photos"],
                       "the file-heavy tree shouldn't also be carrying a multi-GB file")

        // Byte-balanced, that same split would look lopsided (100MB vs 1.5GB);
        // by work it's close, which is what actually governs finishing time.
        let costs = plans.map { $0.cost }.sorted()
        XCTAssertLessThan(Double(costs[1]) / Double(costs[0]), 1.5,
                          "streams should be roughly balanced by work, got costs \(costs)")
    }

    func testCostIsReportedPerPlanAndSumsOverItsItems() {
        let items = [
            SizedItem(name: "a", sizeKB: 100, entryCount: 3),
            SizedItem(name: "b", sizeKB: 50, entryCount: 2),
        ]
        let plans = SplitPlanner.plan(items: items, streamCount: 1)
        XCTAssertEqual(plans.count, 1)
        let expected = (100 + 3 * SplitPlanner.perEntryCostKB) + (50 + 2 * SplitPlanner.perEntryCostKB)
        XCTAssertEqual(plans[0].cost, expected)
        XCTAssertEqual(plans[0].totalKB, 150, "totalKB should stay a real byte count, not the cost estimate")
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

        // And the resulting split should now actually use all four streams.
        let plans = SplitPlanner.plan(items: refined, streamCount: 4)
        XCTAssertEqual(plans.count, 4)
    }

    func testAlreadyBalancedItemsAreLeftAloneWithoutScanning() async {
        let items = (1...4).map { SizedItem(name: "item\($0)", sizeKB: 1000, entryCount: 10) }
        var expandCalled = false
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { _ in
            expandCalled = true
            return []
        }
        XCTAssertFalse(expandCalled, "nothing exceeds a fair share, so no extra directory scan should run")
        XCTAssertEqual(refined.count, 4)
    }

    /// Every item becomes an rsync command-line argument, so exploding a
    /// directory of tens of thousands of entries would blow past ARG_MAX.
    func testDirectoryWithTooManyChildrenIsLeftIntact() async {
        let items = [
            SizedItem(name: "maildir", sizeKB: 900_000, entryCount: 100_000),
            SizedItem(name: "small", sizeKB: 1_000, entryCount: 1),
        ]
        let refined = await SplitPlanner.refine(items: items, streamCount: 4) { _ in
            (1...(SplitPlanner.maxChildrenToExpand + 1)).map {
                SizedItem(name: "maildir/m\($0)", sizeKB: 1, entryCount: 1)
            }
        }
        XCTAssertEqual(Set(refined.map { $0.name }), ["maildir", "small"],
                       "should keep the parent rather than emit thousands of arguments")
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
        let plans = SplitPlanner.plan(items: items, streamCount: 5)
        let allNames = plans.flatMap { $0.itemNames }
        XCTAssertEqual(allNames.count, items.count)
        XCTAssertEqual(Set(allNames), Set(items.map { $0.name }))
    }
}

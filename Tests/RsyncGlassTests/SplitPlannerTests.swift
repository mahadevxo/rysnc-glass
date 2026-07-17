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
        XCTAssertEqual(plans[0].totalKB, 1, "totalKB is floored at 1 so byteShare math never divides by zero")
    }

    func testAllItemsAccountedForNoneDroppedOrDuplicated() {
        let items = (0..<37).map { SizedItem(name: "item\($0)", sizeKB: Int.random(in: 1...5000)) }
        let plans = SplitPlanner.plan(items: items, streamCount: 5)
        let allNames = plans.flatMap { $0.itemNames }
        XCTAssertEqual(allNames.count, items.count)
        XCTAssertEqual(Set(allNames), Set(items.map { $0.name }))
    }
}

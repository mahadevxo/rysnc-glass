import XCTest
@testable import RsyncGlass

final class RsyncProgressParserTests: XCTestCase {
    func testParsesProgress2LineWithCheckTail() {
        let update = RsyncProgressParser.parse("     62,914,560  66%   39.32MB/s    0:00:01 (xfr#1, to-chk=3001/3005)")
        XCTAssertEqual(update, RsyncProgressUpdate(bytes: 62_914_560, percent: 66, checkedEntries: 4))
    }

    func testParsesProgress2LineWithoutTail() {
        let update = RsyncProgressParser.parse("     42,663,936  45%   38.46MB/s    0:00:01  ")
        XCTAssertEqual(update, RsyncProgressUpdate(bytes: 42_663_936, percent: 45, checkedEntries: nil))
    }

    func testParsesIncrementalRecursionAndRsync2Tails() {
        XCTAssertEqual(RsyncProgressParser.parse("  1,024 100%  1.00kB/s  0:00:00 (xfr#7, ir-chk=10/50)")?.checkedEntries, 40)
        XCTAssertEqual(RsyncProgressParser.parse("  1024 100%  1.00kB/s  0:00:00 (xfer#7, to-check=3/5)")?.checkedEntries, 2)
    }

    func testIgnoresNonProgressLines() {
        XCTAssertNil(RsyncProgressParser.parse("reports/50% done.txt"))
        XCTAssertNil(RsyncProgressParser.parse("sending incremental file list"))
        XCTAssertNil(RsyncProgressParser.parse("⚠︎ rsync error: some files could not be transferred (code 23)"))
    }
}

final class LegProgressTests: XCTestCase {
    /// Numbers from a real run: 90MB in two files plus 3000 tiny ones. By the
    /// time rsync reports 99% of bytes, only a handful of the 3000 files have
    /// been checked — the bar must not claim to be nearly done.
    func testSmallFileTailKeepsProgressHonestWhenBytesAreNearlyDone() {
        let bytesKB = 92_174
        let entries = 3005
        let leg = LegProgress(costKB: Double(bytesKB + entries * SplitPlanner.perEntryCostKB))

        leg.apply(RsyncProgressUpdate(bytes: 94_000_000, percent: 99, checkedEntries: 5), cumulativeBytes: true)
        XCTAssertLessThan(leg.fraction, 0.3, "bytes are 99% done but 3000 files are still to go")

        leg.apply(RsyncProgressUpdate(bytes: 94_385_000, percent: 99, checkedEntries: 1500), cumulativeBytes: true)
        XCTAssertEqual(leg.fraction, 0.6, accuracy: 0.05)

        leg.apply(RsyncProgressUpdate(bytes: 94_385_733, percent: 100, checkedEntries: 3005), cumulativeBytes: true)
        XCTAssertEqual(leg.fraction, 1, accuracy: 0.01)
    }

    func testEntryCountCarriesOverBetweenUpdatesAndNeverGoesBackwards() {
        let leg = LegProgress(costKB: 1000)
        leg.apply(RsyncProgressUpdate(bytes: 0, percent: 0, checkedEntries: 4), cumulativeBytes: true)  // 512KB
        let afterEntries = leg.fraction
        leg.apply(RsyncProgressUpdate(bytes: 102_400, percent: 10, checkedEntries: nil), cumulativeBytes: true)
        XCTAssertGreaterThan(leg.fraction, afterEntries, "bytes add on top of the entries already checked")
        let before = leg.fraction
        leg.apply(RsyncProgressUpdate(bytes: 0, percent: 0, checkedEntries: 0), cumulativeBytes: true)
        XCTAssertEqual(leg.fraction, before)
    }

    func testUnindexedLegFollowsRsyncPercentage() {
        let leg = LegProgress(costKB: nil)
        leg.apply(RsyncProgressUpdate(bytes: 5_000, percent: 42, checkedEntries: nil), cumulativeBytes: true)
        XCTAssertEqual(leg.fraction, 0.42, accuracy: 0.001)
        XCTAssertEqual(leg.bytes, 5_000)
    }

    /// A relay stream: two items of different weight, each downloaded then
    /// uploaded, with the second item's download overlapping the first's
    /// upload the way pipelined mode runs them.
    func testRelayStreamWeighsItemsByCostAcrossConcurrentLegs() {
        let stream = StreamState(id: 0)
        stream.totalCostKB = (300 + 100) * 2

        let bigDown = stream.beginLeg(costKB: 300)
        bigDown.apply(RsyncProgressUpdate(bytes: 150 * 1024, percent: 50, checkedEntries: nil), cumulativeBytes: true)
        stream.recompute()
        XCTAssertEqual(stream.progressFraction, 150.0 / 800, accuracy: 0.001)
        stream.endLeg(bigDown, succeeded: true)
        XCTAssertEqual(stream.progressFraction, 300.0 / 800, accuracy: 0.001)

        let bigUp = stream.beginLeg(costKB: 300)
        let smallDown = stream.beginLeg(costKB: 100)
        bigUp.apply(RsyncProgressUpdate(bytes: 30 * 1024, percent: 10, checkedEntries: nil), cumulativeBytes: true)
        smallDown.apply(RsyncProgressUpdate(bytes: 100 * 1024, percent: 100, checkedEntries: nil), cumulativeBytes: true)
        stream.recompute()
        XCTAssertEqual(stream.progressFraction, (300.0 + 30 + 100) / 800, accuracy: 0.001)
        XCTAssertEqual(stream.bytesTransferred, (150 + 30 + 100) * 1024)
    }

    func testLateProgressLineAfterLegEndsStillCountsItsBytes() {
        let stream = StreamState(id: 0)
        stream.totalCostKB = 100
        let leg = stream.beginLeg(costKB: 100)
        stream.endLeg(leg, succeeded: true)
        leg.apply(RsyncProgressUpdate(bytes: 4096, percent: 100, checkedEntries: 1), cumulativeBytes: true)
        stream.recompute()
        XCTAssertEqual(stream.bytesTransferred, 4096)
        XCTAssertEqual(stream.progressFraction, 1)
    }
}

final class MetricsTests: XCTestCase {
    func testRateWindowMeasuresOverTrailingSpan() {
        var window = RateWindow(span: 5)
        XCTAssertNil(window.rate)
        window.add(0, at: 0)
        window.add(100, at: 1)
        XCTAssertEqual(window.rate ?? 0, 100, accuracy: 0.001)
        // Fast early on, slower now — the old samples age out.
        for t in 2...10 { window.add(100 + Double(t - 1) * 10, at: TimeInterval(t)) }
        XCTAssertEqual(window.rate ?? 0, 10, accuracy: 0.001)
    }

    func testSpeedPicksUnitToSuitTheRate() {
        XCTAssertTrue(TransferFormat.speed(2_500).hasSuffix("KB/s"), TransferFormat.speed(2_500))
        XCTAssertTrue(TransferFormat.speed(38_500_000).hasSuffix("MB/s"), TransferFormat.speed(38_500_000))
        XCTAssertTrue(TransferFormat.speed(1_200_000_000).hasSuffix("GB/s"), TransferFormat.speed(1_200_000_000))
    }

    func testPercentNeverRoundsUpToDone() {
        XCTAssertEqual(TransferFormat.percent(0.9999), "99.9%")
        XCTAssertEqual(TransferFormat.percent(1), "100.0%")
        XCTAssertEqual(TransferFormat.percent(0.423), "42.3%")
    }

    func testDurationFormatting() {
        XCTAssertEqual(TransferFormat.duration(42), "0:42")
        XCTAssertEqual(TransferFormat.duration(725), "12:05")
        XCTAssertEqual(TransferFormat.duration(3729), "1:02:09")
    }
}

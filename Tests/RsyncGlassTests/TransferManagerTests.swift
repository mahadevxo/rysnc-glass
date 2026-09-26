import XCTest
@testable import RsyncGlass

/// Integration tests that exercise real `rsync` processes against real local
/// files — these are the tests that actually answer "does this behavior work,"
/// as opposed to unit tests of pure logic.
final class TransferManagerTests: XCTestCase {
    private var testDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDir = FileManager.default.temporaryDirectory.appendingPathComponent("RsyncGlassTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDir)
        try super.tearDownWithError()
    }

    private func waitForTerminal(_ manager: TransferManager, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch manager.state.phase {
            case .finished, .cancelled:
                return
            default:
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// cancel() flips state.phase and releases isTransferActive synchronously,
    /// but the rsync processes it signalled exit asynchronously afterward.
    /// Awaiting the job's own Task is what actually waits for that teardown —
    /// the right thing to do before inspecting on-disk state after a cancel.
    private func waitForJobToUnwind(_ manager: TransferManager) async {
        await manager.jobTask?.value
    }

    /// Waits until rsync has written at least some bytes into `directory`.
    /// While a transfer is in flight the data sits in a hidden temp file
    /// (`.big.bin.XXXXXX`); `--partial` renames it into place on interruption.
    private func waitForBytesInFlight(in directory: URL, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
                if let size = attrs?[.size] as? Int, size > 0 { return true }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func localEndpoint(label: String, path: URL) -> Endpoint {
        let endpoint = Endpoint(label: label)
        endpoint.kind = .local
        endpoint.localPath = path.path
        return endpoint
    }

    // MARK: - Parallel streams

    func testParallelStreamsActuallySplitAcrossMultipleProcesses() async throws {
        let source = testDir.appendingPathComponent("src")
        let target = testDir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // Several top-level items of different sizes so the split planner has
        // something meaningful to balance, with distinct-enough content that a
        // byte comparison after transfer actually proves something.
        let items: [(name: String, byte: UInt8, size: Int)] = [
            ("big1", 0x11, 400_000),
            ("big2", 0x22, 300_000),
            ("small1", 0x33, 50_000),
            ("small2", 0x44, 50_000),
            ("small3", 0x55, 50_000),
        ]
        for item in items {
            let data = Data(repeating: item.byte, count: item.size)
            try data.write(to: source.appendingPathComponent(item.name))
        }

        let sourceEndpoint = localEndpoint(label: "Source", path: source)
        let targetEndpoint = localEndpoint(label: "Target", path: target)
        let options = RsyncOptions()
        options.streamCount = 3

        let manager = TransferManager()
        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)
        await waitForTerminal(manager)

        guard case .finished(let success) = manager.state.phase else {
            XCTFail("expected a finished phase, got \(manager.state.phase)")
            return
        }
        XCTAssertTrue(success)

        // Real parallel transfer: more than one stream should actually have
        // been used, not silently collapsed to a single rsync process.
        XCTAssertGreaterThan(manager.state.streams.count, 1, "expected multiple streams for 5 items with streamCount=3")
        XCTAssertLessThanOrEqual(manager.state.streams.count, 3)

        for stream in manager.state.streams {
            XCTAssertEqual(stream.exitCode, 0)
            XCTAssertEqual(stream.progressFraction, 1, accuracy: 0.001)
        }

        // Byte-for-byte identical result, regardless of which stream carried which file.
        for item in items {
            let srcData = try Data(contentsOf: source.appendingPathComponent(item.name))
            let dstData = try Data(contentsOf: target.appendingPathComponent(item.name))
            XCTAssertEqual(srcData, dstData, "\(item.name) should be byte-identical after a parallel transfer")
        }

        // Every item must land exactly once across all streams — none dropped, none duplicated.
        let allItemNames = manager.state.streams.flatMap { $0.itemNames }
        XCTAssertEqual(Set(allItemNames), Set(items.map { $0.name }))
        XCTAssertEqual(allItemNames.count, items.count)

        XCTAssertEqual(manager.state.overallProgress, 1, accuracy: 0.001, "the work streams report should add up to the whole job")
    }

    func testSingleStreamWhenStreamCountIsOneEvenWithMultipleFiles() async throws {
        let source = testDir.appendingPathComponent("src1")
        let target = testDir.appendingPathComponent("dst1")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("f1.txt"))
        try Data("b".utf8).write(to: source.appendingPathComponent("f2.txt"))

        let options = RsyncOptions()
        options.streamCount = 1

        let manager = TransferManager()
        manager.start(source: localEndpoint(label: "Source", path: source), target: localEndpoint(label: "Target", path: target), options: options)
        await waitForTerminal(manager)

        XCTAssertEqual(manager.state.streams.count, 1)
        XCTAssertEqual(manager.state.overallProgress, 1, accuracy: 0.001)
        XCTAssertEqual((try? Data(contentsOf: target.appendingPathComponent("f1.txt"))), Data("a".utf8))
        XCTAssertEqual((try? Data(contentsOf: target.appendingPathComponent("f2.txt"))), Data("b".utf8))
    }

    // MARK: - Resume

    func testResumeAfterCancelPicksUpFromPartialTransferRatherThanRestarting() async throws {
        let source = testDir.appendingPathComponent("rsrc")
        let target = testDir.appendingPathComponent("rdst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let payload = Data(repeating: 0x7A, count: 20_000_000) // 20MB
        try payload.write(to: source.appendingPathComponent("big.bin"))

        let options = RsyncOptions()
        options.streamCount = 1
        // Repeated-byte content compresses to almost nothing, which would let
        // a compressed transfer race past --bwlimit's throttling (measured in
        // wire bytes) before we get a chance to cancel — so turn -z off here.
        options.compress = false
        options.bandwidthLimitKBps = "2000" // ~2MB/s, so 20MB takes ~10s — enough time to cancel mid-flight

        let manager = TransferManager()
        let sourceEndpoint = localEndpoint(label: "Source", path: source)
        let targetEndpoint = localEndpoint(label: "Target", path: target)

        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)
        // Wait for rsync to actually be writing rather than sleeping a fixed
        // interval: on a loaded machine its startup and file-list phase can
        // eat the whole budget, and cancelling before a single byte lands
        // leaves no partial file and fails a test that isn't really broken.
        let started = await waitForBytesInFlight(in: target)
        XCTAssertTrue(started, "rsync never began writing to the target — can't test resume without a partial file")
        manager.cancel()
        // cancel() flips state.phase to .cancelled synchronously, but the
        // underlying rsync process's actual SIGTERM/exit/flush happens
        // asynchronously afterward — wait for the job's task to finish
        // before inspecting the partial file on disk.
        await waitForJobToUnwind(manager)

        guard case .cancelled = manager.state.phase else {
            XCTFail("expected cancelled phase, got \(manager.state.phase)")
            return
        }

        let partialAttrs = try? FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("big.bin").path)
        let partialSize = partialAttrs?[.size] as? Int
        XCTAssertNotNil(partialSize, "cancelling mid-transfer with --partial should leave a partial file behind")
        if let partialSize {
            XCTAssertLessThan(partialSize, payload.count, "partial file shouldn't already be the full size")
        }

        // Resume: same manager, same endpoints/options.
        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)
        await waitForTerminal(manager, timeout: 30)

        guard case .finished(let success) = manager.state.phase else {
            XCTFail("expected finished phase after resume, got \(manager.state.phase)")
            return
        }
        XCTAssertTrue(success)

        let finalData = try Data(contentsOf: target.appendingPathComponent("big.bin"))
        XCTAssertEqual(finalData, payload, "resumed transfer should end up byte-identical to source")
    }

    // MARK: - Re-entrancy guard

    func testCallingStartTwiceBackToBackDoesNotSpawnTwoJobs() async throws {
        let source = testDir.appendingPathComponent("rasrc")
        let target = testDir.appendingPathComponent("radst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("f.txt"))

        let manager = TransferManager()
        let options = RsyncOptions()
        let sourceEndpoint = localEndpoint(label: "Source", path: source)
        let targetEndpoint = localEndpoint(label: "Target", path: target)

        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)
        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)

        await waitForTerminal(manager)

        XCTAssertEqual(manager.state.streams.count, 1, "a rapid double Start shouldn't spawn a second overlapping job")
    }

    /// The re-entrancy guard used to outlive the cancel that should have
    /// released it: cancel() flipped the phase (so the UI offered Start again)
    /// but left jobInFlight set until the background task finished unwinding,
    /// and start() silently returned in the meantime. Clicking Start right
    /// after Cancel did nothing at all.
    func testCancellingThenImmediatelyStartingADifferentTransferRunsIt() async throws {
        let source = testDir.appendingPathComponent("csrc")
        let otherSource = testDir.appendingPathComponent("osrc")
        let target = testDir.appendingPathComponent("cdst")
        for dir in [source, otherSource, target] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Big enough, and throttled enough, to still be running when cancelled.
        try Data(repeating: 0x5A, count: 20_000_000).write(to: source.appendingPathComponent("big.bin"))
        try Data("second transfer".utf8).write(to: otherSource.appendingPathComponent("other.txt"))

        let options = RsyncOptions()
        options.streamCount = 1
        options.compress = false
        options.bandwidthLimitKBps = "2000"

        let manager = TransferManager()
        manager.start(source: localEndpoint(label: "Source", path: source),
                      target: localEndpoint(label: "Target", path: target),
                      options: options)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(manager.isTransferActive, "should still be transferring before we cancel")

        manager.cancel()
        // Deliberately no wait here — this is the exact race the bug lived in.
        let secondOptions = RsyncOptions()
        secondOptions.streamCount = 1
        manager.start(source: localEndpoint(label: "Source", path: otherSource),
                      target: localEndpoint(label: "Target", path: target),
                      options: secondOptions)

        await waitForTerminal(manager, timeout: 30)

        guard case .finished(let success) = manager.state.phase else {
            XCTFail("second transfer should have run and finished, but phase is \(manager.state.phase)")
            return
        }
        XCTAssertTrue(success, "second transfer should have succeeded")

        let delivered = try Data(contentsOf: target.appendingPathComponent("other.txt"))
        XCTAssertEqual(delivered, Data("second transfer".utf8),
                       "the transfer started right after cancel should actually have moved its file")
    }

    /// A cancelled job that's still winding down must not report its own
    /// outcome over the top of the job the user started next.
    func testCancelledJobDoesNotOverwriteTheNextJobsResult() async throws {
        let source = testDir.appendingPathComponent("wsrc")
        let target = testDir.appendingPathComponent("wdst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 20_000_000).write(to: source.appendingPathComponent("big.bin"))

        let options = RsyncOptions()
        options.streamCount = 1
        options.compress = false
        options.bandwidthLimitKBps = "2000"

        let manager = TransferManager()
        let sourceEndpoint = localEndpoint(label: "Source", path: source)
        let targetEndpoint = localEndpoint(label: "Target", path: target)

        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        manager.cancel()

        // Nothing else started — the cancelled job unwinding on its own must
        // leave the phase cancelled, not flip it to finished.
        await waitForJobToUnwind(manager)
        XCTAssertEqual(manager.state.phase, .cancelled,
                       "a cancelled job's own teardown shouldn't report a terminal success/failure")
        XCTAssertFalse(manager.isTransferActive, "cancel should release the start guard")
    }

    /// Cancelling during the indexing scan has to actually stop the job.
    /// Killing the scan makes it return nothing, which looks exactly like
    /// "this source can't be split" — so without an explicit check the job
    /// falls back to a single stream and transfers everything the user just
    /// cancelled, with the phase left stuck mid-flight.
    func testCancellingDuringIndexingDoesNotStartTheTransferAnyway() async throws {
        let source = testDir.appendingPathComponent("isrc")
        let target = testDir.appendingPathComponent("idst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // Enough entries that walking them takes long enough to cancel inside.
        for group in 0..<40 {
            let dir = source.appendingPathComponent("g\(group)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<250 {
                try Data("x".utf8).write(to: dir.appendingPathComponent("f\(i)"))
            }
        }

        let options = RsyncOptions()
        options.streamCount = 4

        let manager = TransferManager()
        manager.start(source: localEndpoint(label: "Source", path: source),
                      target: localEndpoint(label: "Target", path: target),
                      options: options)

        // Cancel as soon as the scan is under way.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !manager.state.statusMessage.contains("Indexing") {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        manager.cancel()
        await waitForJobToUnwind(manager)

        XCTAssertEqual(manager.state.phase, .cancelled,
                       "cancelling during indexing should leave the job cancelled, not running or finished")

        let delivered = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        XCTAssertTrue(delivered.isEmpty,
                      "nothing should have been transferred after cancelling during indexing, got \(delivered.count) item(s)")
    }

    // MARK: - Deep splitting (rsync -R)

    /// A source dominated by one directory used to be a single stream no
    /// matter how many were requested, because balancing can only move whole
    /// top-level items. Splitting inside it needs rsync -R, and the risk of
    /// -R is layout: the subfolders have to land nested under their parent,
    /// not flattened into the target root.
    func testDominantDirectoryIsSplitAcrossStreamsAndStillLandsNested() async throws {
        let source = testDir.appendingPathComponent("dsrc")
        let target = testDir.appendingPathComponent("ddst")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // One dominant folder of four sizeable subfolders, plus a scrap file.
        let photos = source.appendingPathComponent("photos")
        for year in ["2019", "2020", "2021", "2022"] {
            let dir = photos.appendingPathComponent(year)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<5 {
                try Data(repeating: UInt8(i), count: 400_000).write(to: dir.appendingPathComponent("p\(i).jpg"))
            }
        }
        try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))

        let options = RsyncOptions()
        options.streamCount = 4

        let manager = TransferManager()
        manager.start(source: localEndpoint(label: "Source", path: source),
                      target: localEndpoint(label: "Target", path: target),
                      options: options)
        await waitForTerminal(manager, timeout: 60)

        guard case .finished(let success) = manager.state.phase else {
            XCTFail("expected finished phase, got \(manager.state.phase)")
            return
        }
        XCTAssertTrue(success, "transfer should succeed")

        XCTAssertGreaterThan(manager.state.streams.count, 1,
                             "a source dominated by one directory should still use multiple streams")

        // The whole point of -R: nested layout preserved, nothing flattened.
        for year in ["2019", "2020", "2021", "2022"] {
            for i in 0..<5 {
                let landed = target.appendingPathComponent("photos/\(year)/p\(i).jpg")
                XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path),
                              "photos/\(year)/p\(i).jpg should land nested under photos/")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(year).path),
                           "\(year) must not be flattened into the target root")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("note.txt").path))
    }

    /// Deep splitting must not change what a transfer produces — same bytes,
    /// same tree, whether or not the source got split inside a directory.
    func testDeepSplitTransferMatchesSourceExactly() async throws {
        let source = testDir.appendingPathComponent("esrc")
        let target = testDir.appendingPathComponent("edst")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let big = source.appendingPathComponent("big")
        for sub in ["a", "b", "c"] {
            let dir = big.appendingPathComponent(sub).appendingPathComponent("inner")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<4 {
                try Data(repeating: UInt8(i &+ 1), count: 300_000).write(to: dir.appendingPathComponent("f\(i).bin"))
            }
        }

        let options = RsyncOptions()
        options.streamCount = 3

        let manager = TransferManager()
        manager.start(source: localEndpoint(label: "Source", path: source),
                      target: localEndpoint(label: "Target", path: target),
                      options: options)
        await waitForTerminal(manager, timeout: 60)

        for sub in ["a", "b", "c"] {
            for i in 0..<4 {
                let rel = "big/\(sub)/inner/f\(i).bin"
                let src = try Data(contentsOf: source.appendingPathComponent(rel))
                let dst = try Data(contentsOf: target.appendingPathComponent(rel))
                XCTAssertEqual(src, dst, "\(rel) should be byte-identical")
            }
        }
    }

    // MARK: - Clear log

    func testClearLogEmptiesLogWithoutTouchingPhaseOrStreams() {
        let manager = TransferManager()
        manager.state.appendLog("line 1")
        manager.state.appendLog("line 2")
        XCTAssertEqual(manager.state.logLines.count, 2)

        manager.clearLog()

        XCTAssertTrue(manager.state.logLines.isEmpty)
        XCTAssertEqual(manager.state.phase, .idle)
    }

    // MARK: - Remote-to-remote relay: item-by-item disk-bounded pipeline
    //
    // These call TransferManager.runRelayDirectory/runRelaySingleFile directly
    // with local-kind endpoints rather than through the public start() API.
    // The real remote-to-remote path additionally requires two reachable SSH
    // hosts (exercised only for the failure/routing case below, using an
    // unreachable host); there's no SSH loopback available in this test
    // environment. What's new and worth verifying here — item-by-item
    // relaying that deletes each item from staging as soon as it lands on
    // the target, so a transfer can exceed this Mac's free disk — is
    // orchestration logic in TransferManager that doesn't care whether the
    // underlying rsync process happens to go over SSH or a local path.

    func testDirectoryRelaySequentialNeverHoldsMoreThanOneItemInStagingAtOnce() async throws {
        let source = testDir.appendingPathComponent("relay-seq-src")
        let staging = testDir.appendingPathComponent("relay-seq-staging")
        let target = testDir.appendingPathComponent("relay-seq-dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let itemCount = 3
        for i in 0..<itemCount {
            let data = Data(repeating: UInt8(i + 1), count: 1_500_000) // 1.5MB, distinct byte per item
            try data.write(to: source.appendingPathComponent("item\(i)"))
        }

        let options = RsyncOptions()
        options.streamCount = 1
        options.compress = false // repeated-byte content would defeat --bwlimit's throttling otherwise
        options.bandwidthLimitKBps = "1500" // ~1.5MB/s, so each leg of each item takes ~1s

        let manager = TransferManager()
        var maxObservedStagingItems = 0
        let pollTask = Task {
            while !Task.isCancelled {
                // Exclude the relayed-items manifest — it's bookkeeping for
                // resume-skip, not one of the data items being disk-bounded.
                let count = (try? FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0 != ".rsyncglass-relayed-items" }.count) ?? 0
                maxObservedStagingItems = max(maxObservedStagingItems, count)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let outcome = await manager.runRelayDirectory(
            source: localEndpoint(label: "Source", path: source),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: options
        )
        pollTask.cancel()

        XCTAssertEqual(outcome, .success)
        XCTAssertLessThanOrEqual(maxObservedStagingItems, 1, "sequential relay should process one item at a time per stream — never the whole set at once")

        let remainingStagingItems = try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0 != ".rsyncglass-relayed-items" }
        XCTAssertTrue(remainingStagingItems.isEmpty, "every item should be deleted from staging once it's relayed")

        for i in 0..<itemCount {
            let expected = Data(repeating: UInt8(i + 1), count: 1_500_000)
            let actual = try Data(contentsOf: target.appendingPathComponent("item\(i)"))
            XCTAssertEqual(actual, expected, "item\(i) should be byte-identical after relay")
        }
    }

    /// The relay splits inside a dominant directory too, which means its
    /// items are nested paths. Two things have to survive that: the target
    /// layout (rsync -R on both legs, not flattened), and disk-bounding —
    /// each subfolder must still be deleted from staging as it completes,
    /// including the parent directory it left behind.
    func testRelaySplitsInsideADominantDirectoryAndStaysDiskBounded() async throws {
        let source = testDir.appendingPathComponent("relay-deep-src")
        let staging = testDir.appendingPathComponent("relay-deep-staging")
        let target = testDir.appendingPathComponent("relay-deep-dst")
        for dir in [staging, target] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let years = ["2018", "2019", "2020", "2021", "2022", "2023"]
        for (index, year) in years.enumerated() {
            let dir = source.appendingPathComponent("photos").appendingPathComponent(year)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index + 1), count: 1_500_000).write(to: dir.appendingPathComponent("p.jpg"))
        }

        let streamCount = 3
        let options = RsyncOptions()
        options.streamCount = streamCount
        options.compress = false
        options.bandwidthLimitKBps = "1500" // ~1s per leg, so polling can see staging mid-flight

        let manager = TransferManager()
        var maxObservedStagedPayload = 0
        let pollTask = Task {
            while !Task.isCancelled {
                // Count actual payload files anywhere under staging, ignoring
                // the manifest — nested items mean depth, not just top level.
                let all = FileManager.default.enumerator(atPath: staging.path)?.allObjects as? [String] ?? []
                let payload = all.filter { $0.hasSuffix("p.jpg") }
                maxObservedStagedPayload = max(maxObservedStagedPayload, payload.count)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let outcome = await manager.runRelayDirectory(
            source: localEndpoint(label: "Source", path: source),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: options
        )
        pollTask.cancel()

        XCTAssertEqual(outcome, .success)

        // Nested layout preserved on the target, nothing flattened.
        for (index, year) in years.enumerated() {
            let landed = target.appendingPathComponent("photos/\(year)/p.jpg")
            XCTAssertEqual(try? Data(contentsOf: landed), Data(repeating: UInt8(index + 1), count: 1_500_000),
                           "photos/\(year)/p.jpg should relay through nested and byte-identical")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("\(year)/p.jpg").path),
                           "\(year) must not be flattened into the target root")
        }

        // Disk-bounding is per stream: each holds one item at a time, so with
        // 6 items over 3 streams staging never holds more than 3 — not all 6.
        XCTAssertLessThanOrEqual(maxObservedStagedPayload, streamCount,
                                 "relay should hold at most one item per stream in staging, even when items are nested")
        XCTAssertGreaterThan(maxObservedStagedPayload, 0, "polling should have caught staging mid-flight at least once")

        let leftovers = (FileManager.default.enumerator(atPath: staging.path)?.allObjects as? [String] ?? [])
            .filter { $0 != ".rsyncglass-relayed-items" }
        XCTAssertTrue(leftovers.isEmpty,
                      "staging should be empty afterwards — including the parent dirs nested items leave behind, got \(leftovers)")
    }

    func testDirectoryRelayPipelinedOverlapsButStaysDiskBoundedAndCorrect() async throws {
        let source = testDir.appendingPathComponent("relay-pipe-src")
        let staging = testDir.appendingPathComponent("relay-pipe-staging")
        let target = testDir.appendingPathComponent("relay-pipe-dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let itemCount = 3
        for i in 0..<itemCount {
            let data = Data(repeating: UInt8(i + 1), count: 1_500_000)
            try data.write(to: source.appendingPathComponent("item\(i)"))
        }

        let options = RsyncOptions()
        options.streamCount = 1
        options.compress = false
        options.bandwidthLimitKBps = "1500"
        options.pipelineRelayLegs = true

        let manager = TransferManager()
        var maxObservedStagingItems = 0
        let pollTask = Task {
            while !Task.isCancelled {
                // Exclude the relayed-items manifest — it's bookkeeping for
                // resume-skip, not one of the data items being disk-bounded.
                let count = (try? FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0 != ".rsyncglass-relayed-items" }.count) ?? 0
                maxObservedStagingItems = max(maxObservedStagingItems, count)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let outcome = await manager.runRelayDirectory(
            source: localEndpoint(label: "Source", path: source),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: options
        )
        pollTask.cancel()

        XCTAssertEqual(outcome, .success)
        // Pipelined mode overlaps upload(i) with download(i+1), so up to two
        // items can exist in staging at once — but never the whole set.
        XCTAssertLessThanOrEqual(maxObservedStagingItems, 2, "pipelined relay overlaps by at most one item ahead")
        XCTAssertLessThan(maxObservedStagingItems, itemCount, "pipelined relay should still never hold every item in staging at once")

        let remainingStagingItems = try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0 != ".rsyncglass-relayed-items" }
        XCTAssertTrue(remainingStagingItems.isEmpty)

        for i in 0..<itemCount {
            let expected = Data(repeating: UInt8(i + 1), count: 1_500_000)
            let actual = try Data(contentsOf: target.appendingPathComponent("item\(i)"))
            XCTAssertEqual(actual, expected, "item\(i) should be byte-identical after a pipelined relay")
        }
    }

    func testSingleFileRelayDownloadsThenUploadsSuccessfully() async throws {
        let source = testDir.appendingPathComponent("relay-sf-src")
        let staging = testDir.appendingPathComponent("relay-sf-staging")
        let target = testDir.appendingPathComponent("relay-sf-dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let filePath = source.appendingPathComponent("bigfile.bin")
        let data = Data(repeating: 0x5A, count: 500_000)
        try data.write(to: filePath)

        let manager = TransferManager()
        let outcome = await manager.runRelaySingleFile(
            source: localEndpoint(label: "Source", path: filePath),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: RsyncOptions()
        )

        XCTAssertEqual(outcome, .success)
        let targetData = try Data(contentsOf: target.appendingPathComponent("bigfile.bin"))
        XCTAssertEqual(targetData, data)
    }

    // MARK: - Dry run

    func testDryRunDirectoryRelayPreviewsWithoutUploadingOrFailing() async throws {
        let source = testDir.appendingPathComponent("relay-dry-src")
        let staging = testDir.appendingPathComponent("relay-dry-staging")
        let target = testDir.appendingPathComponent("relay-dry-dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        try Data("a".utf8).write(to: source.appendingPathComponent("item0"))
        try Data("b".utf8).write(to: source.appendingPathComponent("item1"))

        let options = RsyncOptions()
        options.streamCount = 1
        options.dryRun = true

        let manager = TransferManager()
        let outcome = await manager.runRelayDirectory(
            source: localEndpoint(label: "Source", path: source),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: options
        )

        XCTAssertEqual(outcome, .success, "a dry run should preview cleanly, not fail because the upload leg has nothing staged to point at")
        let targetContents = try FileManager.default.contentsOfDirectory(atPath: target.path)
        XCTAssertTrue(targetContents.isEmpty, "dry run must not actually upload anything to the target")
    }

    func testDryRunDoesNotDeleteRealLeftoverStagedItemFromAnInterruptedRealRun() async throws {
        let source = testDir.appendingPathComponent("relay-dry-leftover-src")
        let staging = testDir.appendingPathComponent("relay-dry-leftover-staging")
        let target = testDir.appendingPathComponent("relay-dry-leftover-dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let payload = Data("real leftover data".utf8)
        try payload.write(to: source.appendingPathComponent("leftover.bin"))
        // Simulate a prior REAL relay that downloaded this item into staging
        // but was interrupted before uploading/deleting it — exactly the
        // resumable state the staging path is meant to preserve.
        try payload.write(to: staging.appendingPathComponent("leftover.bin"))

        let options = RsyncOptions()
        options.streamCount = 1
        options.dryRun = true

        let manager = TransferManager()
        let outcome = await manager.runRelayDirectory(
            source: localEndpoint(label: "Source", path: source),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: options
        )

        XCTAssertEqual(outcome, .success)
        let stagedData = try Data(contentsOf: staging.appendingPathComponent("leftover.bin"))
        XCTAssertEqual(stagedData, payload, "a dry run must never delete real staged data left over from an interrupted real relay")
    }

    // MARK: - Resume skips already-relayed items

    func testResumeSkipsItemsAlreadyRelayedInAnEarlierRunInsteadOfRedownloading() async throws {
        let source = testDir.appendingPathComponent("relay-resume-src")
        let staging = testDir.appendingPathComponent("relay-resume-staging")
        let target = testDir.appendingPathComponent("relay-resume-dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        for i in 0..<2 {
            try Data([UInt8(i)]).write(to: source.appendingPathComponent("item\(i)"))
        }

        let options = RsyncOptions()
        options.streamCount = 1

        let firstOutcome = await TransferManager().runRelayDirectory(
            source: localEndpoint(label: "Source", path: source),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: options
        )
        XCTAssertEqual(firstOutcome, .success)

        // A resumed run reuses the same staging path (it's deterministic
        // per source/target pair) — every item is already marked relayed,
        // so this should skip straight to done instead of re-downloading.
        let secondManager = TransferManager()
        let start = Date()
        let secondOutcome = await secondManager.runRelayDirectory(
            source: localEndpoint(label: "Source", path: source),
            staging: localEndpoint(label: "Staging", path: staging),
            target: localEndpoint(label: "Target", path: target),
            options: options
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(secondOutcome, .success)
        XCTAssertLessThan(elapsed, 1.0, "skipping already-relayed items should be near-instant, not spawn rsync again for each one")
        XCTAssertTrue(secondManager.state.logLines.contains { $0.contains("already relayed") })
    }

    // MARK: - Remote-to-remote relay routing

    func testBothEndpointsRemoteRoutesThroughRelayAndFailsGracefullyWithoutServer() async throws {
        let source = Endpoint(label: "Source")
        source.kind = .remote
        source.host = "127.0.0.1"
        source.port = "2" // nothing listens here
        source.username = "nobody"
        source.remotePath = "/tmp/x"
        source.authMethod = .key

        let target = Endpoint(label: "Target")
        target.kind = .remote
        target.host = "127.0.0.1"
        target.port = "3"
        target.username = "nobody"
        target.remotePath = "/tmp/y"
        target.authMethod = .key

        let manager = TransferManager()
        manager.start(source: source, target: target, options: RsyncOptions())
        await waitForTerminal(manager, timeout: 15)

        guard case .finished(let success) = manager.state.phase else {
            XCTFail("expected a finished (failed) phase, got \(manager.state.phase)")
            return
        }
        XCTAssertFalse(success, "an unreachable relay leg should fail, not silently succeed")
        XCTAssertTrue(manager.state.logLines.contains { $0.contains("relaying through a local staging folder") })
    }

    // MARK: - Independent windows and live metrics

    /// Each window owns its own manager. Two transfers started side by side
    /// must both actually run at the same time and both land intact — before,
    /// every window shared one manager, so the second Start was swallowed.
    /// Also checks the live figures a running transfer shows.
    func testTwoManagersRunIndependentTransfersConcurrentlyWithLiveMetrics() async throws {
        var managers: [TransferManager] = []
        var sources: [URL] = []
        var targets: [URL] = []
        for index in 0..<2 {
            let source = testDir.appendingPathComponent("win\(index)-src")
            let target = testDir.appendingPathComponent("win\(index)-dst")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var payload = Data(count: 1_500_000)
            payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            try payload.write(to: source.appendingPathComponent("payload.bin"))
            for n in 0..<50 { try Data("\(n)".utf8).write(to: source.appendingPathComponent("small\(n).txt")) }
            sources.append(source)
            targets.append(target)

            let options = RsyncOptions()
            options.compress = false
            options.bandwidthLimitKBps = "400"
            let manager = TransferManager()
            manager.start(source: localEndpoint(label: "Source", path: source), target: localEndpoint(label: "Target", path: target), options: options)
            managers.append(manager)
        }

        var sawBothActive = false
        var sawSpeed = false
        var sawEstimate = false
        var lastProgress = [0.0, 0.0]
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, managers.contains(where: { $0.isTransferActive }) {
            if managers.allSatisfy({ $0.state.phase == .running }) { sawBothActive = true }
            for (index, manager) in managers.enumerated() where manager.state.phase == .running {
                let progress = manager.state.overallProgress
                XCTAssertGreaterThanOrEqual(progress, lastProgress[index], "progress must never move backwards")
                lastProgress[index] = progress
                if manager.state.bytesPerSecond > 0 { sawSpeed = true }
                if manager.state.secondsRemaining != nil { sawEstimate = true }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(sawBothActive, "both transfers should have been running at the same time")
        XCTAssertTrue(sawSpeed, "a running transfer should report its speed")
        XCTAssertTrue(sawEstimate, "a running transfer should estimate time remaining")

        for (index, manager) in managers.enumerated() {
            XCTAssertEqual(manager.state.phase, .finished(success: true))
            XCTAssertEqual(manager.state.overallProgress, 1, accuracy: 0.001)
            XCTAssertGreaterThan(manager.state.elapsed ?? 0, 2, "elapsed should cover the throttled transfer")
            XCTAssertGreaterThanOrEqual(manager.state.bytesTransferred, 1_500_000)
            // Average speed once done, in the right ballpark for the 400KB/s cap.
            XCTAssertEqual(manager.state.bytesPerSecond, 400 * 1024, accuracy: 250 * 1024)
            let src = try Data(contentsOf: sources[index].appendingPathComponent("payload.bin"))
            let dst = try Data(contentsOf: targets[index].appendingPathComponent("payload.bin"))
            XCTAssertEqual(src, dst)
        }
        XCTAssertTrue(TransferManager.active.isEmpty)
    }

    /// The shape that used to pin one stream: nearly everything in a single
    /// flat folder of many files. It has to be opened up (one du walk,
    /// totalled per child) and dealt out so every stream gets a share, and
    /// it still has to land nested and intact.
    func testFlatFolderOfManyFilesIsSpreadAcrossEveryStream() async throws {
        let source = testDir.appendingPathComponent("flat-src")
        let target = testDir.appendingPathComponent("flat-dst")
        let dataset = source.appendingPathComponent("dataset")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for n in 0..<600 {
            try Data(repeating: UInt8(n % 251), count: 2_000 + n * 10).write(to: dataset.appendingPathComponent("img\(n).jpg"))
        }
        try Data("x".utf8).write(to: source.appendingPathComponent("readme.txt"))

        let options = RsyncOptions()
        options.streamCount = 4
        let manager = TransferManager()
        manager.start(source: localEndpoint(label: "Source", path: source), target: localEndpoint(label: "Target", path: target), options: options)
        await waitForTerminal(manager)

        XCTAssertEqual(manager.state.phase, .finished(success: true))
        XCTAssertEqual(manager.state.streams.count, 4)
        for stream in manager.state.streams {
            XCTAssertGreaterThan(stream.itemNames.filter { $0.hasPrefix("dataset/") }.count, 0,
                                 "stream \(stream.id + 1) should have carried part of the dataset folder")
        }
        let taken = manager.state.streams.flatMap { $0.itemNames }
        XCTAssertEqual(taken.count, Set(taken).count, "no item should be sent twice")
        XCTAssertEqual(manager.state.overallProgress, 1, accuracy: 0.001)

        for n in [0, 299, 599] {
            let name = "dataset/img\(n).jpg"
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(name)), try Data(contentsOf: source.appendingPathComponent(name)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("img0.jpg").path), "must not be flattened")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("dataset").path).count, 600)
    }
}

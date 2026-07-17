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

    /// Unlike state.phase (which cancel() flips synchronously), isTransferActive
    /// only clears once the job's background task has actually finished
    /// tearing down its processes — the right thing to wait on before
    /// inspecting on-disk state right after a cancel.
    private func waitUntilInactive(_ manager: TransferManager, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.isTransferActive, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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

        let shares = manager.state.streams.map { $0.byteShare }
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 0.01, "byte shares across streams should sum to ~1")
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
        XCTAssertEqual(manager.state.streams.first?.byteShare, 1)
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
        try await Task.sleep(nanoseconds: 2_000_000_000) // let ~4MB transfer
        manager.cancel()
        // cancel() flips state.phase to .cancelled synchronously, but the
        // underlying rsync process's actual SIGTERM/exit/flush happens
        // asynchronously afterward — wait for that to truly finish (tracked
        // by isTransferActive) before inspecting the partial file on disk.
        await waitUntilInactive(manager, timeout: 5)

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
}

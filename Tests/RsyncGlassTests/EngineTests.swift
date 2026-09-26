import XCTest
@testable import RsyncGlass

final class RcloneLogLineTests: XCTestCase {
    func testStatsLineWeighsFilesAsWellAsBytes() {
        // 3000 small files, nearly all the bytes (one big file) already sent.
        let line = #"{"level":"notice","msg":"...","stats":{"bytes":94000000,"totalBytes":94385733,"checks":0,"totalChecks":0,"transfers":2,"totalTransfers":3002,"speed":0}}"#
        guard case .stats(let bytes, let fraction)? = RcloneLogLine.parse(line) else {
            return XCTFail("expected stats")
        }
        XCTAssertEqual(bytes, 94_000_000)
        XCTAssertLessThan(fraction, 0.3, "bytes nearly done, but thousands of files still to go")
    }

    func testMessageLineCarriesObjectAndText() {
        let line = #"{"level":"info","msg":"Copied (new)","object":"photos/a.jpg","source":"x"}"#
        guard case .message(let level, let text, let object)? = RcloneLogLine.parse(line) else {
            return XCTFail("expected message")
        }
        XCTAssertEqual(level, "info")
        XCTAssertEqual(text, "Copied (new)")
        XCTAssertEqual(object, "photos/a.jpg")
    }

    func testRsyncOutputIsNotMistakenForRclone() {
        XCTAssertNil(RcloneLogLine.parse("     62,914,560  66%   39.32MB/s    0:00:01"))
        XCTAssertNil(RcloneLogLine.parse("sending incremental file list"))
    }

    /// rclone must be told to ask for the key types known_hosts actually
    /// holds, or it asks for its own favourite and calls the difference a
    /// key mismatch.
    func testHostKeyAlgorithmsFollowWhatKnownHostsRecorded() {
        XCTAssertEqual(RcloneEngine.hostKeyAlgorithms(forRecordedTypes: ["ssh-ed25519"]), "ssh-ed25519")
        XCTAssertEqual(RcloneEngine.hostKeyAlgorithms(forRecordedTypes: ["ssh-rsa", "ssh-ed25519"]), "ssh-ed25519 rsa-sha2-512 rsa-sha2-256 ssh-rsa")
        XCTAssertNil(RcloneEngine.hostKeyAlgorithms(forRecordedTypes: []))
    }

    func testSftpPathsAreHomeRelativeWithoutTilde() {
        XCTAssertEqual(RcloneEngine.sftpPath("/srv/data"), "/srv/data")
        XCTAssertEqual(RcloneEngine.sftpPath("~/backups"), "backups")
        XCTAssertEqual(RcloneEngine.sftpPath("~"), "")
    }
}

final class ServerToServerTests: XCTestCase {
    func testParsesRsyncVersionLines() {
        XCTAssertTrue(ServerToServer.parseVersion("rsync  version 3.2.7  protocol version 31") == (3, 2))
        XCTAssertTrue(ServerToServer.parseVersion("openrsync: protocol version 29\nrsync version 2.6.9 compatible") == (2, 6))
    }

    func testCapabilitiesNeedBothEndsForProtectArgsButOnlySourceForProgress() {
        let mixed = ServerToServer.Capabilities(sourceRsync: (3, 2), targetRsync: (2, 6))
        XCTAssertTrue(mixed.supportsInfoProgress2)
        XCTAssertFalse(mixed.supportsProtectArgs)
        let old = ServerToServer.Capabilities(sourceRsync: (2, 6), targetRsync: (3, 2))
        XCTAssertFalse(old.supportsInfoProgress2)
    }

    func testPasswordTargetIsRefusedBeforeAnythingStarts() async {
        let source = Endpoint(label: "Source")
        source.kind = .remote
        let target = Endpoint(label: "Target")
        target.kind = .remote
        target.authMethod = .password
        do {
            try await ServerToServer(source: source, target: target).prepare()
            XCTFail("a password target can't be reached from the source without handing it the password")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("password"))
        }
    }
}

/// Runs real rclone transfers. rclone's built-in ":local" backend stands in
/// for a cloud remote, so the whole cloud path runs with no network or
/// account.
final class RcloneTransferTests: XCTestCase {
    private var testDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(CommandLocator.rclone == nil, "rclone isn't installed")
        testDir = FileManager.default.temporaryDirectory.appendingPathComponent("RcloneTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testDir { try? FileManager.default.removeItem(at: testDir) }
        try super.tearDownWithError()
    }

    private func waitForTerminal(_ manager: TransferManager, timeout: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch manager.state.phase {
            case .finished, .cancelled: return
            default: try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func testCloudTargetTransfersWithRcloneAndReportsProgress() async throws {
        let source = testDir.appendingPathComponent("src")
        let nested = source.appendingPathComponent("photos/2019")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        var payload = Data(count: 3_000_000)
        payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try payload.write(to: source.appendingPathComponent("big.bin"))
        for n in 0..<200 { try Data("file \(n)".utf8).write(to: nested.appendingPathComponent("p\(n).txt")) }
        let cloudRoot = testDir.appendingPathComponent("bucket")

        let sourceEndpoint = Endpoint(label: "Source")
        sourceEndpoint.kind = .local
        sourceEndpoint.localPath = source.path
        let targetEndpoint = Endpoint(label: "Target")
        targetEndpoint.kind = .cloud
        targetEndpoint.cloudRemote = ":local"
        targetEndpoint.cloudPath = cloudRoot.path

        let options = RsyncOptions()
        options.streamCount = 4
        options.bandwidthLimitKBps = "1500"  // ~2s, so progress is seen mid-flight
        let manager = TransferManager()
        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)

        var sawPartialProgress = false
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, manager.isTransferActive {
            let progress = manager.state.overallProgress
            if progress > 0 && progress < 1 { sawPartialProgress = true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await waitForTerminal(manager)

        XCTAssertEqual(manager.state.phase, .finished(success: true), manager.state.logLines.suffix(10).joined(separator: "\n"))
        XCTAssertTrue(sawPartialProgress, "rclone's stats should drive the progress bar while it runs")
        XCTAssertEqual(manager.state.overallProgress, 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(manager.state.bytesTransferred, 3_000_000)
        XCTAssertEqual(try Data(contentsOf: cloudRoot.appendingPathComponent("big.bin")), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloudRoot.appendingPathComponent("photos/2019").path).count, 200)
        XCTAssertTrue(manager.state.logLines.contains { $0.contains("transferring with rclone") })
        XCTAssertFalse(manager.state.logLines.contains { $0.contains("\"stats\"") }, "raw JSON stats shouldn't flood the log")
    }

    func testDeleteOnACloudTargetSyncsAwayExtraneousFiles() async throws {
        let source = testDir.appendingPathComponent("src2")
        let cloudRoot = testDir.appendingPathComponent("bucket2")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
        try Data("stale".utf8).write(to: cloudRoot.appendingPathComponent("stale.txt"))

        let sourceEndpoint = Endpoint(label: "Source")
        sourceEndpoint.localPath = source.path
        let targetEndpoint = Endpoint(label: "Target")
        targetEndpoint.kind = .cloud
        targetEndpoint.cloudRemote = ":local"
        targetEndpoint.cloudPath = cloudRoot.path

        let options = RsyncOptions()
        options.delete = true
        let manager = TransferManager()
        manager.start(source: sourceEndpoint, target: targetEndpoint, options: options)
        await waitForTerminal(manager)

        XCTAssertEqual(manager.state.phase, .finished(success: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudRoot.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudRoot.appendingPathComponent("stale.txt").path), "delete should map to rclone sync")
    }
}

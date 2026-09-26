import XCTest
@testable import RsyncGlass

/// End-to-end transfers against two real SSH servers. Skipped unless the
/// environment points at them; see the README's "End-to-end tests" section
/// for the Docker setup this expects:
///   RG_E2E_HOST       address both servers are published on (the Mac's LAN
///                     IP, so the source server can reach the target too)
///   RG_E2E_KEY        private key both servers accept, for user "tester"
///   RG_E2E_PASSWORD   password for "tester" on both
/// Source server on port 2221 with test data under /data; target on 2222,
/// also published on 127.0.0.1:2232 — a port only this Mac can reach.
final class SSHEndToEndTests: XCTestCase {
    private var host = ""
    private var keyPath = ""
    private var password = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        guard let host = env["RG_E2E_HOST"], let key = env["RG_E2E_KEY"], let password = env["RG_E2E_PASSWORD"] else {
            throw XCTSkip("RG_E2E_HOST / RG_E2E_KEY / RG_E2E_PASSWORD not set")
        }
        (self.host, self.keyPath, self.password) = (host, key, password)
    }

    private func server(_ label: String, host: String? = nil, port: Int, path: String, password: Bool = false) -> Endpoint {
        let endpoint = Endpoint(label: label)
        endpoint.kind = .remote
        endpoint.host = host ?? self.host
        endpoint.port = String(port)
        endpoint.username = "tester"
        endpoint.remotePath = path
        if password {
            endpoint.authMethod = .password
            endpoint.password = self.password
        } else {
            endpoint.keyPath = keyPath
        }
        return endpoint
    }

    @discardableResult
    private func docker(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A fingerprint of every file's path and contents under `path`.
    private func treeHash(container: String, path: String) throws -> String {
        try docker(["exec", container, "sh", "-c", "cd \(path) && find . -type f -exec md5sum {} + | sort -k2 | md5sum"])
    }

    private func run(_ source: Endpoint, _ target: Endpoint, _ options: RsyncOptions) async -> TransferManager {
        let manager = TransferManager()
        manager.start(source: source, target: target, options: options)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if case .finished = manager.state.phase { break }
            if case .cancelled = manager.state.phase { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return manager
    }

    private func log(_ manager: TransferManager) -> String {
        manager.state.logLines.filter { !$0.contains("%") }.joined(separator: "\n")
    }

    func testDirectServerToServerNeverRoutesDataThroughThisMac() async throws {
        try docker(["exec", "rg-dst", "rm", "-rf", "/data/direct"])
        let options = RsyncOptions()
        options.streamCount = 3
        let manager = await run(server("Source", port: 2221, path: "/data/src"), server("Target", port: 2222, path: "/data/direct"), options)

        XCTAssertEqual(manager.state.phase, .finished(success: true), log(manager))
        XCTAssertTrue(log(manager).contains("Direct server-to-server"), log(manager))
        XCTAssertFalse(log(manager).contains("Streaming server-to-server"))
        XCTAssertTrue(log(manager).contains("on the local network — compression off"), log(manager))
        XCTAssertGreaterThan(manager.state.streams.count, 1, "the chunk queue should drive direct transfers too")
        XCTAssertEqual(manager.state.overallProgress, 1, accuracy: 0.001)
        XCTAssertEqual(try treeHash(container: "rg-dst", path: "/data/direct"), try treeHash(container: "rg-src", path: "/data/src"))
    }

    func testStreamsWithRcloneWhenDirectIsTurnedOff() async throws {
        try docker(["exec", "rg-dst", "rm", "-rf", "/data/streamed"])
        let options = RsyncOptions()
        options.streamCount = 4
        options.directServerToServer = false
        let manager = await run(server("Source", port: 2221, path: "/data/src"), server("Target", port: 2222, path: "/data/streamed"), options)

        XCTAssertEqual(manager.state.phase, .finished(success: true), log(manager))
        XCTAssertTrue(log(manager).contains("Streaming server-to-server with rclone"), log(manager))
        XCTAssertEqual(try treeHash(container: "rg-dst", path: "/data/streamed"), try treeHash(container: "rg-src", path: "/data/src"))
    }

    /// The target given as 127.0.0.1:2232 works from this Mac but means the
    /// source server itself from the source's side — so the direct probe
    /// has to fail and hand over to rclone.
    func testFallsBackToRcloneWhenTheSourceCantReachTheTarget() async throws {
        try docker(["exec", "rg-dst", "rm", "-rf", "/data/fallback"])
        let options = RsyncOptions()
        options.streamCount = 2
        let manager = await run(server("Source", port: 2221, path: "/data/src"), server("Target", host: "127.0.0.1", port: 2232, path: "/data/fallback"), options)

        XCTAssertEqual(manager.state.phase, .finished(success: true), log(manager))
        XCTAssertTrue(log(manager).contains("Can't transfer server-to-server directly"), log(manager))
        XCTAssertTrue(log(manager).contains("Streaming server-to-server with rclone"), log(manager))
        XCTAssertEqual(try treeHash(container: "rg-dst", path: "/data/fallback"), try treeHash(container: "rg-src", path: "/data/src"))
    }

    func testPasswordLoginWorksThroughRclone() async throws {
        try docker(["exec", "rg-dst", "rm", "-rf", "/data/password"])
        let options = RsyncOptions()
        options.directServerToServer = false
        let manager = await run(server("Source", port: 2221, path: "/data/src", password: true), server("Target", port: 2222, path: "/data/password"), options)

        XCTAssertEqual(manager.state.phase, .finished(success: true), log(manager))
        XCTAssertEqual(try treeHash(container: "rg-dst", path: "/data/password"), try treeHash(container: "rg-src", path: "/data/src"))
    }

    func testLargeSingleFileDownloadsInParallelPieces() async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("RGE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let target = Endpoint(label: "Target")
        target.localPath = local.path

        let options = RsyncOptions()
        options.streamCount = 4
        let manager = await run(server("Source", port: 2221, path: "/data/big.iso"), target, options)

        XCTAssertEqual(manager.state.phase, .finished(success: true), log(manager))
        XCTAssertTrue(log(manager).contains("downloading it as 4 parallel pieces"), log(manager))
        let landed = local.appendingPathComponent("big.iso")
        let size = try FileManager.default.attributesOfItem(atPath: landed.path)[.size] as? Int
        XCTAssertEqual(size, 1_153_433_600)
        let remoteSum = try docker(["exec", "rg-src", "sh", "-c", "md5sum < /data/big.iso"]).split(separator: " ").first.map(String.init)
        let localSum = try shell("/sbin/md5", ["-q", landed.path])
        XCTAssertEqual(localSum, remoteSum)
    }

    private func shell(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

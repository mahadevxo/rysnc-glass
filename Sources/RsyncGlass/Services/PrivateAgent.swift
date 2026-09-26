import Foundation

/// A throwaway ssh-agent holding just the keys one transfer needs. Used where
/// something other than this Mac's own ssh has to authenticate as the user:
/// the source server logging in to the target (forwarded to it), or rclone,
/// which only reads keys from an agent or an explicit file — it doesn't pick
/// up ~/.ssh defaults the way ssh does. Keeping it separate from the login
/// agent means nothing else in there is exposed.
final class PrivateAgent {
    enum AgentError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let detail): return detail
            }
        }
    }

    private var process: Process?
    private var directory: String?
    private(set) var socket: String?

    deinit {
        stop()
    }

    func start() async throws {
        guard socket == nil else { return }
        // Unix socket paths are capped at 104 bytes on macOS, which the
        // per-user temporary directory alone nearly uses up — hence /tmp.
        let directory = "/tmp/rg-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let socket = directory + "/agent.sock"

        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        do {
            try agent.run()
        } catch {
            throw AgentError.failed("ssh-agent didn't start: \(error.localizedDescription)")
        }
        process = agent
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard FileManager.default.fileExists(atPath: socket) else { throw AgentError.failed("ssh-agent didn't start") }
        self.socket = socket
    }

    /// Loads the key `endpoint` logs in with. No key path means whatever ssh
    /// would use by default, which is what ssh-add with no arguments loads.
    /// --apple-use-keychain lets a passphrase-protected key load when its
    /// passphrase is in the Keychain; with nowhere to ask for one otherwise,
    /// it fails here instead.
    func addKey(for endpoint: Endpoint) async throws {
        guard let socket else { throw AgentError.failed("agent isn't running") }
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        let keyPath = (endpoint.keyPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        add.arguments = ["--apple-use-keychain"] + (keyPath.isEmpty ? [] : [keyPath])
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = socket
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment.removeValue(forKey: "DISPLAY")
        add.environment = environment
        add.standardInput = FileHandle.nullDevice
        let result = try await ProcessRunner.run(add)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentError.failed(detail.isEmpty ? "ssh-add exited with \(result.exitCode)" : detail)
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
        socket = nil
    }
}

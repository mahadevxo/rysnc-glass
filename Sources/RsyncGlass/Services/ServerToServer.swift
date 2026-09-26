import Foundation

/// Direct remote-to-remote transfers: ssh into the source and run rsync there,
/// pushing straight to the target. The data never passes through this Mac —
/// no staging disk, no double trip over this Mac's network link — and unlike
/// a streaming relay it keeps everything rsync is good at (delta transfer,
/// permissions and ownership, --partial resume).
///
/// The source still has to log in to the target. Rather than copying a key
/// onto the source, a private ssh-agent holding only the target's key is
/// forwarded for the length of the job: the source can use the key while
/// connected, but never sees it, and nothing else from this Mac's own agent
/// is exposed.
final class ServerToServer {
    struct Capabilities {
        let sourceRsync: (major: Int, minor: Int)
        let targetRsync: (major: Int, minor: Int)

        /// Both sides have to understand --info=progress2 for the running
        /// rsync to accept it; only the source's copy prints it.
        var supportsInfoProgress2: Bool {
            sourceRsync.major > 3 || (sourceRsync.major == 3 && sourceRsync.minor >= 1)
        }
        /// -s changes the protocol, so both ends need 3.0+.
        var supportsProtectArgs: Bool {
            sourceRsync.major >= 3 && targetRsync.major >= 3
        }
    }

    enum SetupError: LocalizedError {
        case passwordTarget
        case agentFailed(String)
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .passwordTarget:
                return "the target uses password login, which can't be handed to the source server without revealing the password to it"
            case .agentFailed(let detail):
                return "couldn't load the target's SSH key into a temporary agent (\(detail))"
            case .unreachable(let detail):
                return detail
            }
        }
    }

    let source: Endpoint
    let target: Endpoint
    private(set) var capabilities: Capabilities?
    private let agent = PrivateAgent()

    init(source: Endpoint, target: Endpoint) {
        self.source = source
        self.target = target
    }

    deinit {
        stop()
    }

    /// Starts the agent and checks the whole path works: rsync on both
    /// servers, and the source able to log in to the target. Throws with a
    /// reason the log can show if any of it doesn't.
    func prepare(onStart: ((Process) -> Void)? = nil) async throws {
        guard target.authMethod == .key else { throw SetupError.passwordTarget }
        do {
            try await agent.start()
            try await agent.addKey(for: target)
        } catch {
            throw SetupError.agentFailed(error.localizedDescription)
        }

        let probe = """
        if ! command -v rsync >/dev/null 2>&1; then echo "RG_SOURCE_NO_RSYNC"; exit 0; fi
        echo "RG_SOURCE_RSYNC $(rsync --version 2>/dev/null | head -n 2 | tr '\\n' ' ')"
        ssh \(targetSSHOptions.map(PathUtilities.shellQuote).joined(separator: " ")) \(PathUtilities.shellQuote(targetLogin)) \
          'if command -v rsync >/dev/null 2>&1; then echo "RG_TARGET_RSYNC $(rsync --version 2>/dev/null | head -n 2 | tr "\\n" " ")"; else echo RG_TARGET_NO_RSYNC; fi' 2>&1 \
          | sed 's/^/RG_TARGET_SAYS /'
        """
        let process = try makeSourceProcess(script: probe)
        let result = try await ProcessRunner.run(process, onStart: onStart)
        // isNewline, not "\n": ssh ends its own warnings with "\r\n", which
        // Swift treats as one Character that splitting on "\n" never matches —
        // so the first-connection "Permanently added" warning would swallow
        // the line after it.
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)

        if lines.contains("RG_SOURCE_NO_RSYNC") {
            throw SetupError.unreachable("rsync isn't installed on \(source.host)")
        }
        guard let sourceLine = lines.first(where: { $0.hasPrefix("RG_SOURCE_RSYNC ") }) else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError.unreachable("couldn't run commands on \(source.host)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        let targetLines = lines.filter { $0.hasPrefix("RG_TARGET_SAYS ") }.map { String($0.dropFirst("RG_TARGET_SAYS ".count)) }
        if targetLines.contains("RG_TARGET_NO_RSYNC") {
            throw SetupError.unreachable("rsync isn't installed on \(target.host)")
        }
        guard let targetLine = targetLines.first(where: { $0.hasPrefix("RG_TARGET_RSYNC ") }) else {
            let said = targetLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            throw SetupError.unreachable("\(source.host) couldn't log in to \(target.host) as \(target.username)\(said.isEmpty ? "" : ": \(said)")")
        }
        capabilities = Capabilities(
            sourceRsync: Self.parseVersion(sourceLine),
            targetRsync: Self.parseVersion(targetLine)
        )
    }

    /// An rsync run on the source, pushing `itemNames` (or the whole source
    /// path when nil) to the target.
    func buildProcess(itemNames: [String]?, sourceIsDirectory: Bool, options: RsyncOptions) throws -> Process {
        guard let capabilities else { throw SetupError.unreachable("server-to-server path wasn't checked first") }
        var args = ["rsync"]
        args.append(contentsOf: options.baseFlags(onLocalNetwork: options.isLocalNetwork(host: target.host)))
        args.append(capabilities.supportsInfoProgress2 ? "--info=progress2" : "--progress")
        if capabilities.supportsProtectArgs { args.append("-s") }
        args.append(contentsOf: ["-e", (["ssh"] + targetSSHOptions).joined(separator: " ")])

        if let itemNames, !itemNames.isEmpty {
            // Same "/./" marker scheme as RsyncCommandBuilder: nested names
            // need -R to land nested rather than flattened into the root.
            let needsRelative = itemNames.contains { $0.contains("/") }
            if needsRelative { args.append("-R") }
            for name in itemNames {
                args.append(needsRelative
                    ? PathUtilities.withTrailingSlash(source.remotePath) + "./" + name
                    : PathUtilities.join(source.remotePath, name))
            }
        } else {
            args.append(sourceIsDirectory ? PathUtilities.withTrailingSlash(source.remotePath) : source.remotePath)
        }
        args.append(targetLogin + ":" + PathUtilities.withTrailingSlash(target.remotePath))

        return try makeSourceProcess(script: args.map(PathUtilities.shellQuote).joined(separator: " "))
    }

    func stop() {
        agent.stop()
    }

    // MARK: - Private

    private var targetLogin: String { "\(target.username)@\(target.host)" }

    /// How the source connects on to the target. Key only, via the forwarded
    /// agent: BatchMode stops a missing key turning into a password prompt
    /// nobody can answer. accept-new records the target's host key in the
    /// source's known_hosts on first use, the same policy this app uses itself.
    private var targetSSHOptions: [String] {
        ["-p", String(target.portNumber), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
    }

    private func makeSourceProcess(script: String) throws -> Process {
        try SSHConnectionBuilder.makeProcess(
            for: source,
            remoteCommand: "sh -c " + PathUtilities.shellQuote(script),
            forwardingAgent: agent.socket
        )
    }

    /// Reads "rsync version X.Y" specifically: macOS's openrsync leads with
    /// "openrsync: protocol version 29", and taking that 29 as the major
    /// version would hand it flags it doesn't understand.
    static func parseVersion(_ text: String) -> (major: Int, minor: Int) {
        guard let match = text.range(of: #"rsync\s+version\s+(\d+)\.(\d+)"#, options: .regularExpression) else { return (0, 0) }
        let numbers = text[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return (numbers.first ?? 0, numbers.count > 1 ? numbers[1] : 0)
    }
}

import Foundation

/// rclone, for the transfers rsync can't do or does badly:
/// - anything involving cloud storage, via the user's own rclone config;
/// - remote-to-remote when the servers can't reach each other, streamed
///   through this Mac's memory instead of staged on its disk;
/// - one large file from a server, fetched as several parallel byte ranges.
///
/// What it gives up next to rsync: no delta transfer (a changed file is sent
/// whole), no permissions or ownership over SFTP, and an interrupted file
/// starts over rather than resuming.
enum RcloneEngine {
    enum EngineError: LocalizedError {
        case missing

        var errorDescription: String? {
            switch self {
            case .missing:
                return "rclone isn't available. It's bundled with the release build; for a development build install it with: brew install rclone"
            }
        }
    }

    /// Remote names from the user's rclone config, without the trailing ":".
    static func listRemotes() async -> [String] {
        guard let rclone = CommandLocator.rclone else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclone)
        process.arguments = ["listremotes", "--ask-password=false"]
        guard let result = try? await ProcessRunner.run(process), result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n")
            .map { String($0.trimmingCharacters(in: .whitespaces).dropLast(1)) }
            .filter { !$0.isEmpty }
    }

    /// - agentSocket: a PrivateAgent holding the keys for any key-auth SSH
    ///   endpoint. rclone's SFTP backend doesn't read ~/.ssh defaults the way
    ///   ssh does; with no key file or password it asks an agent.
    /// - multiThreadStreams: parallel byte ranges per large file (rclone only
    ///   does this when downloading to local disk).
    static func buildProcess(source: Endpoint, target: Endpoint, sourceIsDirectory: Bool, options: RsyncOptions, agentSocket: String?, multiThreadStreams: Int? = nil) async throws -> Process {
        guard let rclone = CommandLocator.rclone else { throw EngineError.missing }
        var environment = ProcessInfo.processInfo.environment
        let sourceSpec = try await spec(for: source, name: "rgsrc", environment: &environment)
        let targetSpec = try await spec(for: target, name: "rgdst", environment: &environment)
        if let agentSocket { environment["SSH_AUTH_SOCK"] = agentSocket }

        // sync deletes extraneous files on the target, like rsync --delete.
        // A single file only ever goes into the target directory with copy.
        let command = options.delete && sourceIsDirectory ? "sync" : "copy"
        let streams = max(options.streamCount, 1)
        var args = [
            command, sourceSpec, targetSpec,
            "--transfers", String(streams),
            "--checkers", String(max(8, streams * 2)),
            "--multi-thread-streams", String(multiThreadStreams ?? streams),
            "--stats", "1s",
            "--stats-log-level", "NOTICE",
            "--use-json-log",
            "--ask-password=false",
        ]
        if options.verbose { args.append("-v") }
        if options.dryRun { args.append("--dry-run") }
        if let bw = Int(options.bandwidthLimitKBps.trimmingCharacters(in: .whitespaces)), bw > 0 {
            args.append(contentsOf: ["--bwlimit", "\(bw)K"])
        }
        for pattern in options.excludeList {
            args.append(contentsOf: ["--exclude", pattern])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclone)
        process.arguments = args
        process.environment = environment
        return process
    }

    /// How rclone should address an endpoint. An SSH host becomes an SFTP
    /// remote defined only in this process's environment, so nothing is
    /// written into the user's rclone config and the password never appears
    /// on a command line.
    private static func spec(for endpoint: Endpoint, name: String, environment: inout [String: String]) async throws -> String {
        switch endpoint.kind {
        case .local:
            return endpoint.localPath
        case .cloud:
            return endpoint.cloudRemote + ":" + endpoint.cloudPath
        case .remote:
            let prefix = "RCLONE_CONFIG_\(name.uppercased())_"
            environment[prefix + "TYPE"] = "sftp"
            environment[prefix + "HOST"] = endpoint.host
            environment[prefix + "USER"] = endpoint.username
            environment[prefix + "PORT"] = String(endpoint.portNumber)
            // The caller has already connected once with ssh, which records
            // the host key (accept-new) — so rclone can verify against it
            // rather than trusting whatever key the server presents.
            // Except for loopback addresses, which ssh deliberately never
            // records or checks (an SSH tunnel looks like 127.0.0.1) — so
            // there'd be no key on file for rclone to find.
            if !isLoopback(endpoint.host) {
                environment[prefix + "KNOWN_HOSTS_FILE"] = knownHostsFile
                if let algorithms = await hostKeyAlgorithms(for: endpoint) {
                    environment[prefix + "HOST_KEY_ALGORITHMS"] = algorithms
                }
            }
            if endpoint.authMethod == .password {
                environment[prefix + "PASS"] = try await RcloneConfig.obscure(endpoint.password)
            }
            return name + ":" + sftpPath(endpoint.remotePath)
        }
    }

    private static let knownHostsFile = NSHomeDirectory() + "/.ssh/known_hosts"

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// The host key types known_hosts has on record for this server, as
    /// rclone's host_key_algorithms. Without it rclone's SSH library asks
    /// for its own favourite type, and if known_hosts only holds a different
    /// one (typical: ssh records just the ed25519 key it was offered) it
    /// reports a key mismatch rather than asking for the type it knows.
    /// ssh-keygen -F does the lookup, so hashed entries match too.
    static func hostKeyAlgorithms(for endpoint: Endpoint) async -> String? {
        let name = endpoint.portNumber == 22 ? endpoint.host : "[\(endpoint.host)]:\(endpoint.portNumber)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-F", name, "-f", knownHostsFile]
        guard let result = try? await ProcessRunner.run(process), result.exitCode == 0 else { return nil }
        let recorded = Set(result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: " ")
            return fields.count >= 2 ? String(fields[1]) : nil
        })
        return hostKeyAlgorithms(forRecordedTypes: recorded)
    }

    /// Strongest first. An RSA key is recorded as "ssh-rsa" but negotiated
    /// with the SHA-2 signature algorithms that modern servers require.
    static func hostKeyAlgorithms(forRecordedTypes recorded: Set<String>) -> String? {
        var algorithms: [String] = []
        for type in ["ssh-ed25519", "ecdsa-sha2-nistp521", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256"] where recorded.contains(type) {
            algorithms.append(type)
        }
        if recorded.contains("ssh-rsa") {
            algorithms.append(contentsOf: ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])
        }
        return algorithms.isEmpty ? nil : algorithms.joined(separator: " ")
    }

    /// rclone's SFTP paths are relative to the login directory unless they
    /// start with "/", and it doesn't expand "~".
    static func sftpPath(_ path: String) -> String {
        if path == "~" { return "" }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
        return path
    }
}

/// One line of rclone's --use-json-log output.
enum RcloneLogLine {
    case stats(bytes: Int64, fraction: Double)
    case message(level: String, text: String, object: String?)

    static func parse(_ line: String) -> RcloneLogLine? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let stats = json["stats"] as? [String: Any] {
            func number(_ key: String) -> Double { (stats[key] as? NSNumber)?.doubleValue ?? 0 }
            // Same weighting as rsync progress: files count as well as bytes,
            // so a tail of small files doesn't read as nearly done. A file
            // rclone skips as unchanged is a check; one it sends is a
            // transfer. Totals grow while it's still listing, which the
            // never-go-backwards rule in LegProgress smooths over.
            let perEntry = Double(SplitPlanner.perEntryCostKB)
            let done = number("bytes") / 1024 + (number("checks") + number("transfers")) * perEntry
            let total = number("totalBytes") / 1024 + (number("totalChecks") + number("totalTransfers")) * perEntry
            return .stats(bytes: Int64(number("bytes")), fraction: total > 0 ? min(done / total, 1) : 0)
        }
        let text = (json["msg"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .message(level: json["level"] as? String ?? "info", text: text, object: json["object"] as? String)
    }
}

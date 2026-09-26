import Foundation

enum SSHConnectionError: LocalizedError {
    case missingSSH
    case missingSSHPass

    var errorDescription: String? {
        switch self {
        case .missingSSH:
            return "Could not find the `ssh` binary on this Mac."
        case .missingSSHPass:
            return "Password auth needs `sshpass`, which isn't installed. Run: brew install hudochenkov/sshpass/sshpass"
        }
    }
}

/// Builds ssh/sshpass command lines for both rsync's `-e` transport option
/// and for standalone ssh calls (listing directories, connection tests).
enum SSHConnectionBuilder {

    /// Common ssh options: skip interactive host-key prompts (no TTY available)
    /// and fail fast on unreachable hosts.
    private static func baseSSHOptions(endpoint: Endpoint) -> [String] {
        var opts = [
            "-p", String(endpoint.portNumber),
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
        ]
        if endpoint.authMethod == .key {
            // No password fallback possible without a TTY, so fail immediately
            // instead of hanging on a password prompt.
            opts.append(contentsOf: ["-o", "BatchMode=yes"])
            let trimmedKey = endpoint.keyPath.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty {
                opts.append(contentsOf: ["-i", trimmedKey])
            }
        }
        return opts
    }

    /// The string to pass as rsync's `-e` argument. rsync word-splits this on
    /// whitespace itself (no shell involved), so paths containing spaces
    /// (e.g. a key file) are not supported here.
    static func rshCommand(for endpoint: Endpoint) throws -> String {
        guard let ssh = CommandLocator.ssh else { throw SSHConnectionError.missingSSH }
        var parts = [ssh]
        parts.append(contentsOf: baseSSHOptions(endpoint: endpoint))
        if endpoint.authMethod == .password {
            guard let sshpass = CommandLocator.sshpass else { throw SSHConnectionError.missingSSHPass }
            parts = [sshpass, "-e", ssh]
            parts.append(contentsOf: baseSSHOptions(endpoint: endpoint))
        }
        return parts.joined(separator: " ")
    }

    /// A ready-to-run Process that executes `remoteCommand` on the endpoint's host via ssh.
    /// - forwardingAgent: an ssh-agent socket to forward to the host, so a
    ///   command running there can log in onward with the keys it holds.
    static func makeProcess(for endpoint: Endpoint, remoteCommand: String, forwardingAgent agentSocket: String? = nil) throws -> Process {
        guard let ssh = CommandLocator.ssh else { throw SSHConnectionError.missingSSH }

        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        var executable = ssh
        var arguments = baseSSHOptions(endpoint: endpoint)

        if endpoint.authMethod == .password {
            guard let sshpass = CommandLocator.sshpass else { throw SSHConnectionError.missingSSHPass }
            executable = sshpass
            arguments = ["-e", ssh] + arguments
            environment["SSHPASS"] = endpoint.password
        }

        if let agentSocket {
            arguments.append(contentsOf: ["-o", "ForwardAgent=yes"])
            environment["SSH_AUTH_SOCK"] = agentSocket
        }

        arguments.append("\(endpoint.username)@\(endpoint.host)")
        arguments.append(remoteCommand)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        return process
    }
}

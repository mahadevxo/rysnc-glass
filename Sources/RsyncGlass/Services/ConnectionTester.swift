import Foundation

enum ConnectionTester {
    static func test(_ endpoint: Endpoint) async -> String {
        guard endpoint.isRemote else { return "Not a remote endpoint." }
        if CommandLocator.ssh == nil {
            return "ssh not found on this Mac."
        }
        if endpoint.authMethod == .password && CommandLocator.sshpass == nil {
            return "Password auth needs sshpass. Install: brew install hudochenkov/sshpass/sshpass"
        }
        do {
            let process = try SSHConnectionBuilder.makeProcess(for: endpoint, remoteCommand: "echo RSYNCGLASS_OK")
            let result = try await ProcessRunner.run(process)
            if result.stdout.contains("RSYNCGLASS_OK") {
                return "Connected successfully."
            } else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "Connection failed (exit \(result.exitCode))." : "Connection failed: \(detail)"
            }
        } catch {
            return "Connection failed: \(error.localizedDescription)"
        }
    }
}

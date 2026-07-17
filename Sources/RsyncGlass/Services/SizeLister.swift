import Foundation

struct SizedItem {
    let name: String
    let sizeKB: Int
}

enum SizeListerError: LocalizedError {
    case notADirectory
    case remoteListingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory:
            return "Source path is a single file, not a directory — nothing to split across streams."
        case .remoteListingFailed(let detail):
            return "Couldn't list the remote directory: \(detail)"
        }
    }
}

/// Lists the top-level entries of a directory (local or remote) along with
/// their sizes, so TransferManager can balance them across parallel streams.
enum SizeLister {

    static func list(for endpoint: Endpoint) async throws -> [SizedItem] {
        if endpoint.isRemote {
            return try await listRemote(endpoint: endpoint)
        } else {
            return try await listLocal(path: endpoint.localPath)
        }
    }

    private static func listLocal(path: String) async throws -> [SizedItem] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw SizeListerError.notADirectory
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: path)
        guard !entries.isEmpty else { return [] }
        guard let duPath = CommandLocator.du else {
            // Fall back to equal weighting if `du` is somehow unavailable.
            return entries.map { SizedItem(name: $0, sizeKB: 1) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: duPath)
        process.arguments = ["-sk"] + entries.map { path + "/" + $0 }
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let result = try await ProcessRunner.run(process)
        return parseDuOutput(result.stdout, stripPrefix: path + "/")
    }

    private static func listRemote(endpoint: Endpoint) async throws -> [SizedItem] {
        let quotedPath = PathUtilities.shellQuote(endpoint.remotePath)
        let remoteCommand = "cd \(quotedPath) && du -sk -- .[!.]* * 2>/dev/null"
        let process = try SSHConnectionBuilder.makeProcess(for: endpoint, remoteCommand: remoteCommand)
        let result = try await ProcessRunner.run(process)
        if result.exitCode != 0 && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SizeListerError.remoteListingFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parseDuOutput(result.stdout, stripPrefix: nil)
    }

    private static func parseDuOutput(_ output: String, stripPrefix: String?) -> [SizedItem] {
        var items: [SizedItem] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let sizeKB = Int(parts[0]) else { continue }
            var name = String(parts[1])
            if let prefix = stripPrefix, name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            if name == "." || name == ".." { continue }
            items.append(SizedItem(name: name, sizeKB: sizeKB))
        }
        return items
    }
}

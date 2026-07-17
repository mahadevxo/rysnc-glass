import Foundation

struct RemoteEntry: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
}

enum RemoteBrowserError: LocalizedError {
    case listingFailed(String)

    var errorDescription: String? {
        switch self {
        case .listingFailed(let detail):
            return detail.isEmpty ? "Couldn't list that folder." : detail
        }
    }
}

/// Lists a remote directory's contents over SSH so EndpointEditor can offer a
/// Browse button for remote paths, the same way NSOpenPanel does for local ones.
enum RemoteBrowser {
    struct Listing {
        let path: String
        let entries: [RemoteEntry]
    }

    /// `path` empty means "start at the SSH login shell's home directory".
    static func list(endpoint: Endpoint, path: String) async throws -> Listing {
        let marker = "@@@RSYNCGLASS_LIST@@@"
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        let cdPart = trimmedPath.isEmpty ? "" : "cd \(PathUtilities.shellQuote(trimmedPath)) && "
        // -F appends a type suffix (/ for dirs) and -L follows symlinks so a
        // symlinked directory still shows as one instead of as "@".
        let remoteCommand = "\(cdPart)pwd && echo \(marker) && ls -1AFL"

        let process = try SSHConnectionBuilder.makeProcess(for: endpoint, remoteCommand: remoteCommand)
        let result = try await ProcessRunner.run(process)

        guard result.exitCode == 0, let markerRange = result.stdout.range(of: marker) else {
            throw RemoteBrowserError.listingFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let resolvedPath = String(result.stdout[result.stdout.startIndex..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let listingText = result.stdout[markerRange.upperBound...]

        var entries: [RemoteEntry] = []
        for line in listingText.split(separator: "\n") {
            guard !line.isEmpty else { continue }
            if let last = line.last, "/*=|%@".contains(last) {
                entries.append(RemoteEntry(name: String(line.dropLast()), isDirectory: last == "/"))
            } else {
                entries.append(RemoteEntry(name: String(line), isDirectory: false))
            }
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        return Listing(path: resolvedPath.isEmpty ? "/" : resolvedPath, entries: entries)
    }
}

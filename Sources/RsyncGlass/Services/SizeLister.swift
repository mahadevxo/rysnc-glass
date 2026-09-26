import Foundation

struct SizedItem {
    let name: String
    let sizeKB: Int
    /// Entries (files and subdirectories) underneath this item, 1 for a plain
    /// file. Bytes alone don't predict how long an item takes to transfer:
    /// rsync pays a per-entry cost in stat calls and protocol round trips, so
    /// a deep tree of small files can take far longer than a single large
    /// file of the same size. SplitPlanner weighs both.
    let entryCount: Int

    init(name: String, sizeKB: Int, entryCount: Int = 1) {
        self.name = name
        self.sizeKB = sizeKB
        self.entryCount = entryCount
    }
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
/// their size and entry count, so TransferManager can balance them across
/// parallel streams.
enum SizeLister {

    /// One `du -ak` walk per top-level item yields both numbers at once: it
    /// prints a line per entry underneath (so the line count is the entry
    /// count) and, walking post-order, finishes with the item's own total
    /// size. Cheaper than a separate `du -sk` and `find | wc -l`, which would
    /// walk every tree twice — and over SSH the whole loop is one round trip.
    /// `.[!.]*` catches dotfiles without matching "." or "..", `..?*` catches
    /// the names those two patterns fall between (a file actually called
    /// "..foo"), and `*` catches everything else.
    private static let entryGlobs = [".[!.]*", "..?*", "*"]

    private static func indexScript(for directory: String) -> String {
        measureScript(root: directory, globs: entryGlobs)
    }

    /// Same measurement, but over the direct children of `parents` (paths
    /// relative to the root) rather than the root's own entries. Names come
    /// back still relative to the root — "photos/2019" — which is exactly the
    /// form rsync -R wants and the form the relay uses as an item name.
    private static func childrenScript(root: String, parents: [String]) -> String {
        measureScript(root: root, globs: parents.flatMap { parent in
            // Quote the parent, leave the glob unquoted so the shell expands it.
            entryGlobs.map { PathUtilities.shellQuote(parent) + "/" + $0 }
        })
    }

    /// Sizes are apparent (bytes in the file), not disk blocks: a 1-byte
    /// file occupies a 4KB block, so a tree of small files would otherwise
    /// index several times larger than the data rsync actually sends, and
    /// progress measured against it would never reach the end. BSD/macOS du
    /// spells that -A, GNU du --apparent-size; anything else falls back to
    /// block sizes rather than failing the scan.
    private static func measureScript(root: String, globs: [String]) -> String {
        """
        if du -A -k /dev/null >/dev/null 2>&1; then A=-A
        elif du --apparent-size -k /dev/null >/dev/null 2>&1; then A=--apparent-size
        else A=; fi
        cd \(PathUtilities.shellQuote(root)) || exit 1
        for e in \(globs.joined(separator: " ")); do
          [ -e "$e" ] || [ -L "$e" ] || continue
          set -- $(du $A -ak -- "$e" 2>/dev/null | awk '{c++; last=$1} END {print last+0, c+0}')
          printf '%s\\t%s\\t%s\\n' "${1:-0}" "${2:-0}" "$e"
        done
        """
    }

    /// - onStart: forwarded to ProcessRunner so the caller can terminate the
    ///   indexing process if the user cancels mid-scan.
    static func list(for endpoint: Endpoint, onStart: ((Process) -> Void)? = nil) async throws -> [SizedItem] {
        try await run(script: indexScript(for: endpoint.path), on: endpoint, onStart: onStart)
    }

    /// Direct children of the given items, for splitting a directory that's
    /// too big to sit on one stream. Returns [] rather than throwing if the
    /// scan fails — the caller can always fall back to the parent items.
    static func listChildren(of parents: [String], in endpoint: Endpoint, onStart: ((Process) -> Void)? = nil) async -> [SizedItem] {
        guard !parents.isEmpty else { return [] }
        let script = childrenScript(root: endpoint.path, parents: parents)
        return (try? await run(script: script, on: endpoint, onStart: onStart)) ?? []
    }

    private static func run(script: String, on endpoint: Endpoint, onStart: ((Process) -> Void)?) async throws -> [SizedItem] {
        if endpoint.isRemote {
            return try await runRemote(script: script, endpoint: endpoint, onStart: onStart)
        } else {
            return try await runLocal(script: script, path: endpoint.localPath, onStart: onStart)
        }
    }

    private static func runLocal(script: String, path: String, onStart: ((Process) -> Void)?) async throws -> [SizedItem] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw SizeListerError.notADirectory
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]

        let result = try await ProcessRunner.run(process, onStart: onStart)
        return parseIndexOutput(result.stdout)
    }

    private static func runRemote(script: String, endpoint: Endpoint, onStart: ((Process) -> Void)?) async throws -> [SizedItem] {
        // Run it through sh explicitly: ssh executes the command with the
        // account's *login* shell, and zsh aborts the whole script on an
        // unmatched glob rather than leaving the pattern literal the way sh
        // does — so on a source with no dotfiles the scan would return
        // nothing at all.
        let remoteCommand = "sh -c " + PathUtilities.shellQuote(script)
        let process = try SSHConnectionBuilder.makeProcess(for: endpoint, remoteCommand: remoteCommand)
        let result = try await ProcessRunner.run(process, onStart: onStart)
        if result.exitCode != 0 && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SizeListerError.remoteListingFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parseIndexOutput(result.stdout)
    }

    /// Parses `sizeKB<TAB>entryCount<TAB>name` lines. Name is taken as
    /// everything after the second tab, so names containing tabs survive.
    private static func parseIndexOutput(_ output: String) -> [SizedItem] {
        var items: [SizedItem] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3,
                  let sizeKB = Int(parts[0]),
                  let entryCount = Int(parts[1]) else { continue }
            let name = String(parts[2])
            if name == "." || name == ".." { continue }
            items.append(SizedItem(name: name, sizeKB: sizeKB, entryCount: max(entryCount, 1)))
        }
        return items
    }
}

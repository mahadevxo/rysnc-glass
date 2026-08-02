import Foundation

/// Locates external binaries this app shells out to. macOS apps launched from
/// Finder don't inherit the user's shell PATH, so we check common install
/// locations explicitly rather than relying on `Process` + PATH lookup alone.
enum CommandLocator {
    private static let searchDirs = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// build_app.sh copies rsync/sshpass in here when it finds them on the
    /// build machine, so the shipped .app works without Homebrew installed.
    /// Checked first so a bundled copy wins over whatever's on the system.
    /// Empty (or absent) in dev builds run via `swift run`/`swift test`.
    private static var bundledBinDir: String? {
        Bundle.main.resourceURL?.appendingPathComponent("bin").path
    }

    /// Whether a binary can actually start on this machine. `isExecutableFile`
    /// only checks the +x bit, which a bundled binary passes even when it
    /// can't run here — the release bundles arm64 builds, so on an Intel Mac
    /// launching one fails with EBADARCH, and a bundled binary whose dylibs
    /// went missing gets killed by dyld. Both need to fall through to a system
    /// install rather than being handed back as if they worked. A nonzero exit
    /// is fine: this only distinguishes "started" from "couldn't start", and
    /// not every binary accepts --version (sshpass wants -V).
    /// Internal rather than private so tests can cover it directly.
    static func canLaunch(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false  // EBADARCH, or not really executable
        }
        process.waitUntilExit()
        // dyld aborts the process when a linked library is missing, rather
        // than letting it exit normally.
        return process.terminationReason != .uncaughtSignal
    }

    private static var cache: [String: String?] = [:]

    static func find(_ binary: String) -> String? {
        if let cached = cache[binary] {
            return cached
        }
        let fm = FileManager.default
        var candidates: [String] = []
        if let bundledBinDir {
            candidates.append(bundledBinDir + "/" + binary)
        }
        candidates.append(contentsOf: searchDirs.map { $0 + "/" + binary })

        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            guard canLaunch(candidate) else { continue }
            cache[binary] = candidate
            return candidate
        }
        cache[binary] = .some(nil)
        return nil
    }

    static var rsync: String? { find("rsync") }
    static var ssh: String? { find("ssh") }
    static var sshpass: String? { find("sshpass") }
    static var du: String? { find("du") }
}

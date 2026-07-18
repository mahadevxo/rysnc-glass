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
    private static var bundledBinDir: String {
        Bundle.main.bundlePath + "/Contents/Resources/bin"
    }

    private static var cache: [String: String?] = [:]

    static func find(_ binary: String) -> String? {
        if let cached = cache[binary] {
            return cached
        }
        let fm = FileManager.default
        let bundled = bundledBinDir + "/" + binary
        if fm.isExecutableFile(atPath: bundled) {
            cache[binary] = bundled
            return bundled
        }
        for dir in searchDirs {
            let candidate = dir + "/" + binary
            if fm.isExecutableFile(atPath: candidate) {
                cache[binary] = candidate
                return candidate
            }
        }
        cache[binary] = .some(nil)
        return nil
    }

    static var rsync: String? { find("rsync") }
    static var ssh: String? { find("ssh") }
    static var sshpass: String? { find("sshpass") }
    static var du: String? { find("du") }
}

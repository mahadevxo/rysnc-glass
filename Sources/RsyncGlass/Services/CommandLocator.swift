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

    private static var cache: [String: String?] = [:]

    static func find(_ binary: String) -> String? {
        if let cached = cache[binary] {
            return cached
        }
        let fm = FileManager.default
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

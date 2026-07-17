import Foundation

enum PathUtilities {
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

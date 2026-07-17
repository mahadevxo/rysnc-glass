import Foundation
import CryptoKit

/// rsync can't transfer directly between two remote hosts, so a remote-to-remote
/// job relays through a local staging folder: download source → staging, then
/// upload staging → target. The staging path is deterministic per source/target
/// pair so an interrupted relay resumes both legs on the next run instead of
/// re-downloading everything.
enum RelayStaging {
    static func path(source: Endpoint, target: Endpoint) -> String {
        let key = "\(source.username)@\(source.host):\(source.remotePath) -> \(target.username)@\(target.host):\(target.remotePath)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let shortHash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return NSHomeDirectory() + "/Library/Caches/com.local.rsyncglass/Relay/" + shortHash
    }
}

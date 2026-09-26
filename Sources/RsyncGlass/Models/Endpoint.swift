import Foundation

enum EndpointKind: String, CaseIterable, Identifiable {
    case local = "Local"
    case remote = "Remote (SSH)"
    case cloud = "Cloud (rclone)"
    var id: String { rawValue }
}

enum AuthMethod: String, CaseIterable, Identifiable, Codable {
    case key = "SSH Key / Agent"
    case password = "Password"
    var id: String { rawValue }
}

@Observable
final class Endpoint {
    var label: String
    var kind: EndpointKind = .local

    // Local
    var localPath: String = ""

    // Remote
    var host: String = ""
    var port: String = "22"
    var username: String = NSUserName()
    var remotePath: String = ""
    var authMethod: AuthMethod = .key
    var keyPath: String = ""
    var password: String = ""

    // Cloud: a remote from the user's rclone config, and a path within it.
    var cloudRemote: String = ""
    var cloudPath: String = ""

    init(label: String) {
        self.label = label
    }

    /// An SSH host. Cloud endpoints aren't "remote" in this sense: rsync
    /// can't reach them, only rclone can.
    var isRemote: Bool { kind == .remote }
    var isCloud: Bool { kind == .cloud }

    var portNumber: Int {
        Int(port) ?? 22
    }

    /// The path portion regardless of local/remote.
    var path: String {
        get {
            switch kind {
            case .local: return localPath
            case .remote: return remotePath
            case .cloud: return cloudPath
            }
        }
        set {
            switch kind {
            case .local: localPath = newValue
            case .remote: remotePath = newValue
            case .cloud: cloudPath = newValue
            }
        }
    }

    var isValid: Bool {
        if isCloud {
            // An empty path is the remote's root, which is a fine target.
            return !cloudRemote.isEmpty
        }
        if isRemote {
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
                && !username.trimmingCharacters(in: .whitespaces).isEmpty
                && !remotePath.trimmingCharacters(in: .whitespaces).isEmpty
                && (authMethod == .key || !password.isEmpty)
        } else {
            return !localPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// user@host:path form used as an rsync remote spec (no trailing slash added here).
    func remoteSpec(path overridePath: String? = nil) -> String {
        let p = overridePath ?? remotePath
        return "\(username)@\(host):\(p)"
    }

    /// A normalized identity string for detecting when source and target
    /// point at the same place (same local path, or same remote user@host:path).
    var resolvedLocationKey: String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        switch kind {
        case .local: return "local:\(p)"
        case .remote: return "\(username)@\(host):\(port)/\(p)"
        case .cloud: return "cloud:\(cloudRemote):\(p)"
        }
    }

    /// Swaps every field except `label`, so this endpoint keeps its identity
    /// (e.g. "Source" stays "Source") while its configured location swaps with `other`.
    func swapContents(with other: Endpoint) {
        let mine = (kind, localPath, host, port, username, remotePath, authMethod, keyPath, password)
        (kind, localPath, host, port, username, remotePath, authMethod, keyPath, password) =
            (other.kind, other.localPath, other.host, other.port, other.username, other.remotePath, other.authMethod, other.keyPath, other.password)
        (other.kind, other.localPath, other.host, other.port, other.username, other.remotePath, other.authMethod, other.keyPath, other.password) = mine
        (cloudRemote, cloudPath, other.cloudRemote, other.cloudPath) = (other.cloudRemote, other.cloudPath, cloudRemote, cloudPath)
    }
}

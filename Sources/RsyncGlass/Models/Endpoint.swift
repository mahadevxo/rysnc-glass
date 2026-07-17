import Foundation

enum EndpointKind: String, CaseIterable, Identifiable {
    case local = "Local"
    case remote = "Remote (SSH)"
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

    init(label: String) {
        self.label = label
    }

    var isRemote: Bool { kind == .remote }

    var portNumber: Int {
        Int(port) ?? 22
    }

    /// The path portion regardless of local/remote.
    var path: String {
        get { isRemote ? remotePath : localPath }
        set {
            if isRemote { remotePath = newValue } else { localPath = newValue }
        }
    }

    var isValid: Bool {
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
}

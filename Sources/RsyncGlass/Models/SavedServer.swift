import Foundation

struct SavedServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: String
    var username: String
    var remotePath: String
    var authMethod: AuthMethod
    var keyPath: String

    var summary: String {
        "\(username)@\(host):\(port)"
    }
}

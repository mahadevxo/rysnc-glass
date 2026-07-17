import Foundation

@Observable
final class ServerStore {
    private static let defaultsKey = "com.local.rsyncglass.savedServers"

    var servers: [SavedServer] = []

    init() {
        load()
    }

    /// Inserts a new server, or replaces the existing one with the same id
    /// (used when re-saving under a name that already matches a saved entry).
    func upsert(_ server: SavedServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    func delete(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        KeychainService.deletePassword(forServerID: server.id)
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        servers = (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

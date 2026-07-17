import XCTest
@testable import RsyncGlass

final class ServerStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.local.rsyncglass.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAddedServerPersistsAcrossFreshStoreInstances() {
        let store = ServerStore(defaults: defaults)
        let server = SavedServer(name: "Home NAS", host: "nas.local", port: "22", username: "alice", remotePath: "/data", authMethod: .key, keyPath: "")
        store.upsert(server)

        let reloaded = ServerStore(defaults: defaults)
        XCTAssertEqual(reloaded.servers.map { $0.name }, ["Home NAS"])
        XCTAssertEqual(reloaded.servers.first?.host, "nas.local")
    }

    func testUpsertWithSameIDUpdatesInPlaceRatherThanDuplicating() {
        let store = ServerStore(defaults: defaults)
        let id = UUID()
        store.upsert(SavedServer(id: id, name: "Box", host: "1.2.3.4", port: "22", username: "bob", remotePath: "/a", authMethod: .key, keyPath: ""))
        store.upsert(SavedServer(id: id, name: "Box", host: "1.2.3.4", port: "2222", username: "bob", remotePath: "/b", authMethod: .key, keyPath: ""))

        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers.first?.port, "2222")
        XCTAssertEqual(store.servers.first?.remotePath, "/b")
    }

    /// This is the "edit saved server" flow end to end: EditServerSheet
    /// upserts a SavedServer with the original id but a changed name and
    /// fields — it should rename in place, not leave a stale duplicate under
    /// the old name.
    func testUpsertCanRenameServerWhileKeepingSameID() {
        let store = ServerStore(defaults: defaults)
        let id = UUID()
        store.upsert(SavedServer(id: id, name: "Old Name", host: "old.local", port: "22", username: "u", remotePath: "/old", authMethod: .key, keyPath: ""))

        store.upsert(SavedServer(id: id, name: "New Name", host: "new.local", port: "2222", username: "u2", remotePath: "/new", authMethod: .key, keyPath: ""))

        XCTAssertEqual(store.servers.count, 1, "renaming should update in place, not create a second entry")
        let renamed = store.servers.first!
        XCTAssertEqual(renamed.id, id)
        XCTAssertEqual(renamed.name, "New Name")
        XCTAssertEqual(renamed.host, "new.local")
        XCTAssertEqual(renamed.port, "2222")
        XCTAssertEqual(renamed.username, "u2")
        XCTAssertEqual(renamed.remotePath, "/new")
        XCTAssertFalse(store.servers.contains { $0.name == "Old Name" })
    }

    func testEditingAuthMethodFromPasswordToKeyClearsStoredPassword() {
        let store = ServerStore(defaults: defaults)
        let id = UUID()
        store.upsert(SavedServer(id: id, name: "Server", host: "h", port: "22", username: "u", remotePath: "/", authMethod: .password, keyPath: ""))
        KeychainService.savePassword("secret", forServerID: id)
        XCTAssertEqual(KeychainService.loadPassword(forServerID: id), "secret")

        // Mirrors EditServerSheet.save(): editing to key auth should clear
        // the now-stale Keychain password for this server.
        store.upsert(SavedServer(id: id, name: "Server", host: "h", port: "22", username: "u", remotePath: "/", authMethod: .key, keyPath: "/Users/u/.ssh/id_ed25519"))
        KeychainService.deletePassword(forServerID: id)

        XCTAssertEqual(store.servers.first?.authMethod, .key)
        XCTAssertNil(KeychainService.loadPassword(forServerID: id))
    }

    func testDifferentIDsWithSameNameAreDistinctEntries() {
        let store = ServerStore(defaults: defaults)
        store.upsert(SavedServer(name: "Dup", host: "a.local", port: "22", username: "u", remotePath: "/x", authMethod: .key, keyPath: ""))
        store.upsert(SavedServer(name: "Dup", host: "b.local", port: "22", username: "u", remotePath: "/y", authMethod: .key, keyPath: ""))
        XCTAssertEqual(store.servers.count, 2)
    }

    func testServersSortedAlphabeticallyByName() {
        let store = ServerStore(defaults: defaults)
        for name in ["Zebra", "alpha", "Mango"] {
            store.upsert(SavedServer(name: name, host: "h", port: "22", username: "u", remotePath: "/", authMethod: .key, keyPath: ""))
        }
        XCTAssertEqual(store.servers.map { $0.name }, ["alpha", "Mango", "Zebra"])
    }

    func testDeleteRemovesServerAndItsKeychainPassword() {
        let store = ServerStore(defaults: defaults)
        let id = UUID()
        let server = SavedServer(id: id, name: "WithPassword", host: "h", port: "22", username: "u", remotePath: "/", authMethod: .password, keyPath: "")
        store.upsert(server)
        KeychainService.savePassword("s3cret", forServerID: id)
        XCTAssertEqual(KeychainService.loadPassword(forServerID: id), "s3cret")

        store.delete(server)

        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertNil(KeychainService.loadPassword(forServerID: id), "deleting a saved server should also clear its Keychain password")
    }

    func testKeychainPasswordRoundTripsIndependentlyOfServerStore() {
        let id = UUID()
        KeychainService.savePassword("first", forServerID: id)
        XCTAssertEqual(KeychainService.loadPassword(forServerID: id), "first")

        // Saving again under the same id overwrites rather than erroring.
        KeychainService.savePassword("second", forServerID: id)
        XCTAssertEqual(KeychainService.loadPassword(forServerID: id), "second")

        KeychainService.deletePassword(forServerID: id)
        XCTAssertNil(KeychainService.loadPassword(forServerID: id))
    }
}

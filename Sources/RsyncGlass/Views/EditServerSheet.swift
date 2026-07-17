import SwiftUI

struct EditServerSheet: View {
    let server: SavedServer
    var onSave: (SavedServer) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var remotePath: String
    @State private var authMethod: AuthMethod
    @State private var keyPath: String
    @State private var password: String

    init(server: SavedServer, onSave: @escaping (SavedServer) -> Void, onCancel: @escaping () -> Void) {
        self.server = server
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: server.name)
        _host = State(initialValue: server.host)
        _port = State(initialValue: server.port)
        _username = State(initialValue: server.username)
        _remotePath = State(initialValue: server.remotePath)
        _authMethod = State(initialValue: server.authMethod)
        _keyPath = State(initialValue: server.keyPath)
        _password = State(initialValue: server.authMethod == .password ? (KeychainService.loadPassword(forServerID: server.id) ?? "") : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Server")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .fieldStyle()
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Host").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("example.com or 10.0.0.5", text: $host)
                        .fieldStyle()
                }
                GridRow {
                    Text("Port").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("22", text: $port)
                        .fieldStyle()
                        .frame(width: 80)
                }
                GridRow {
                    Text("User").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("username", text: $username)
                        .fieldStyle()
                }
                GridRow {
                    Text("Path").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("/remote/path", text: $remotePath)
                        .fieldStyle()
                }
            }

            Picker("", selection: $authMethod) {
                ForEach(AuthMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if authMethod == .key {
                TextField("Key file (optional — uses ssh-agent/default keys)", text: $keyPath)
                    .fieldStyle()
            } else {
                SecureField("Password", text: $password)
                    .fieldStyle()
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        let updated = SavedServer(
            id: server.id,
            name: name.trimmingCharacters(in: .whitespaces),
            host: host,
            port: port,
            username: username,
            remotePath: remotePath,
            authMethod: authMethod,
            keyPath: keyPath
        )

        // Keep Keychain state matching exactly what's in the password field,
        // same as the initial-save flow: switching to key auth or clearing
        // the field removes any previously stored password.
        if authMethod == .password && !password.isEmpty {
            KeychainService.savePassword(password, forServerID: server.id)
        } else {
            KeychainService.deletePassword(forServerID: server.id)
        }

        onSave(updated)
    }
}

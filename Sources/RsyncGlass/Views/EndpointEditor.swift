import SwiftUI
import AppKit

struct EndpointEditor: View {
    @Bindable var endpoint: Endpoint
    var serverStore: ServerStore
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showSaveSheet = false
    @State private var showManageSheet = false
    @State private var showRemoteBrowser = false
    @State private var saveName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(endpoint.label)
                .font(.headline)

            Picker("", selection: $endpoint.kind) {
                ForEach(EndpointKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .alignmentGuide(.endpointRow) { d in d[VerticalAlignment.center] }

            if endpoint.kind == .local {
                localFields
            } else {
                remoteFields
            }
        }
        .frame(minWidth: 340)
        .glassPanel()
        .sheet(isPresented: $showSaveSheet) {
            saveServerSheet
        }
        .sheet(isPresented: $showManageSheet) {
            manageServersSheet
        }
        .sheet(isPresented: $showRemoteBrowser) {
            RemoteBrowserSheet(endpoint: endpoint) { chosenPath in
                endpoint.remotePath = chosenPath
            }
        }
    }

    private var saveServerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Server")
                .font(.headline)
            TextField("Name (e.g. Home NAS)", text: $saveName)
                .fieldStyle()
                .onSubmit { saveCurrentServer() }
            Text("Saves host, port, username, path, and auth method. A saved password is stored in Keychain, not in a plain settings file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                Button("Save") { saveCurrentServer() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var manageServersSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved Servers")
                    .font(.headline)
                Spacer()
                Button("Done") { showManageSheet = false }
            }
            .padding()

            Divider()

            if serverStore.servers.isEmpty {
                Text("No saved servers yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(serverStore.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text(server.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                serverStore.delete(server)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 320)
    }

    private var localFields: some View {
        HStack {
            TextField("/path/to/folder", text: $endpoint.localPath)
                .fieldStyle()
            Button("Browse…") { browseFolder() }
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    if serverStore.servers.isEmpty {
                        Text("No saved servers")
                    } else {
                        ForEach(serverStore.servers) { server in
                            Button {
                                apply(server)
                            } label: {
                                Text(server.name)
                                Text(server.summary)
                            }
                        }
                    }
                    Divider()
                    Button("Manage Saved Servers…") { showManageSheet = true }
                } label: {
                    Label("Saved Servers", systemImage: "server.rack")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    saveName = endpoint.host
                    showSaveSheet = true
                } label: {
                    Label("Save", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(endpoint.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Host").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("example.com or 10.0.0.5", text: $endpoint.host)
                        .fieldStyle()
                }
                GridRow {
                    Text("Port").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("22", text: $endpoint.port)
                        .fieldStyle()
                        .frame(width: 80)
                }
                GridRow {
                    Text("User").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("username", text: $endpoint.username)
                        .fieldStyle()
                }
                GridRow {
                    Text("Path").frame(width: 60, alignment: .leading).font(.caption)
                    TextField("/remote/path", text: $endpoint.remotePath)
                        .fieldStyle()
                    Button("Browse…") { showRemoteBrowser = true }
                        .disabled(endpoint.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Picker("", selection: $endpoint.authMethod) {
                ForEach(AuthMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if endpoint.authMethod == .key {
                HStack {
                    TextField("Key file (optional — uses ssh-agent/default keys)", text: $endpoint.keyPath)
                        .fieldStyle()
                    Button("Browse…") { browseKey() }
                }
            } else {
                SecureField("Password", text: $endpoint.password)
                    .fieldStyle()
            }

            HStack(spacing: 8) {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .buttonStyle(.glass)
                .disabled(isTesting || endpoint.host.trimmingCharacters(in: .whitespaces).isEmpty)

                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.contains("success") ? .green : .red)
                        .lineLimit(2)
                }
            }
        }
    }

    private func apply(_ server: SavedServer) {
        endpoint.host = server.host
        endpoint.port = server.port
        endpoint.username = server.username
        endpoint.remotePath = server.remotePath
        endpoint.authMethod = server.authMethod
        endpoint.keyPath = server.keyPath
        endpoint.password = server.authMethod == .password ? (KeychainService.loadPassword(forServerID: server.id) ?? "") : ""
        testResult = nil
    }

    private func saveCurrentServer() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Saving under a name that already matches a saved entry updates it
        // in place instead of creating a duplicate.
        let existingID = serverStore.servers.first(where: { $0.name == name })?.id
        let server = SavedServer(
            id: existingID ?? UUID(),
            name: name,
            host: endpoint.host,
            port: endpoint.port,
            username: endpoint.username,
            remotePath: endpoint.remotePath,
            authMethod: endpoint.authMethod,
            keyPath: endpoint.keyPath
        )
        serverStore.upsert(server)

        // Keep Keychain state exactly matching what's in the password field
        // right now, so switching to key auth or clearing the field doesn't
        // leave a stale password behind under an updated entry.
        if endpoint.authMethod == .password && !endpoint.password.isEmpty {
            KeychainService.savePassword(endpoint.password, forServerID: server.id)
        } else {
            KeychainService.deletePassword(forServerID: server.id)
        }
        saveName = ""
        showSaveSheet = false
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            endpoint.localPath = url.path
        }
    }

    private func browseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            endpoint.keyPath = url.path
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        testResult = await ConnectionTester.test(endpoint)
        isTesting = false
    }
}

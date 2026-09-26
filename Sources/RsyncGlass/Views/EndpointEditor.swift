import SwiftUI
import AppKit

/// The sheet an EndpointEditor can present. Using one `.sheet(item:)` bound to
/// this instead of three separate `.sheet(isPresented:)` modifiers matters:
/// SwiftUI on macOS doesn't reliably present multiple boolean-driven sheets
/// stacked on the same view — once one has been shown, others attached the
/// same way can silently stop presenting.
private enum EndpointSheet: Identifiable {
    case save
    case manage
    case browse
    case editServer
    var id: Self { self }
}

struct EndpointEditor: View {
    @Bindable var endpoint: Endpoint
    var serverStore: ServerStore
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var activeSheet: EndpointSheet?
    // Set instead of activeSheet directly whenever a sheet is already showing:
    // swapping .sheet(item:) straight from one non-nil value to another (with
    // no nil in between) is unreliable on macOS — it can present blank
    // instead of the new content. dismissing first (activeSheet = nil) and
    // presenting the pending one from onDismiss avoids that.
    @State private var pendingSheet: EndpointSheet?
    @State private var saveName = ""
    @State private var editingServer: SavedServer?
    @State private var cloudRemotes: [String]?

    private func present(_ sheet: EndpointSheet) {
        if activeSheet == nil {
            activeSheet = sheet
        } else {
            pendingSheet = sheet
            activeSheet = nil
        }
    }

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

            switch endpoint.kind {
            case .local: localFields
            case .remote: remoteFields
            case .cloud: cloudFields
            }
        }
        .frame(minWidth: 340)
        .glassPanel()
        .sheet(item: $activeSheet, onDismiss: {
            if let pendingSheet {
                self.pendingSheet = nil
                activeSheet = pendingSheet
            }
        }) { sheet in
            switch sheet {
            case .save:
                saveServerSheet
            case .manage:
                manageServersSheet
            case .browse:
                RemoteBrowserSheet(endpoint: endpoint) { chosenPath in
                    endpoint.remotePath = chosenPath
                }
            case .editServer:
                if let editingServer {
                    EditServerSheet(
                        server: editingServer,
                        onSave: { updated in
                            serverStore.upsert(updated)
                            present(.manage)
                        },
                        onCancel: { present(.manage) }
                    )
                }
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
                Button("Cancel") { activeSheet = nil }
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
                Button("Done") { activeSheet = nil }
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
                                editingServer = server
                                present(.editServer)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
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

    private var cloudFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Remote", selection: $endpoint.cloudRemote) {
                    Text("Choose…").tag("")
                    ForEach(cloudRemotes ?? [], id: \.self) { Text($0).tag($0) }
                }
                Button {
                    Task { cloudRemotes = await RcloneEngine.listRemotes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload remotes from your rclone config")
            }
            TextField("path/in/remote (empty for its root)", text: $endpoint.cloudPath)
                .fieldStyle()
            Text(cloudRemotes?.isEmpty == true
                 ? "No remotes in your rclone config yet. Add one in Terminal with: rclone config"
                 : "Remotes come from your rclone config. Transfers involving cloud storage run with rclone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { if cloudRemotes == nil { cloudRemotes = await RcloneEngine.listRemotes() } }
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
                    Button("Manage Saved Servers…") { present(.manage) }
                } label: {
                    Label("Saved Servers", systemImage: "server.rack")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    saveName = endpoint.host
                    present(.save)
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
                    Button("Browse…") { present(.browse) }
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
        activeSheet = nil
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

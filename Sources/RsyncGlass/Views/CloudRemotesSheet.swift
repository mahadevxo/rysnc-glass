import SwiftUI

/// Lists, tests, deletes and adds rclone remotes. One sheet that navigates in
/// place, rather than a sheet on a sheet — stacked sheets are unreliable on
/// macOS (see EndpointSheet).
struct CloudRemotesSheet: View {
    /// Called on close, with the name of a remote the user just added (so the
    /// endpoint can select it), or nil.
    var onClose: (String?) -> Void

    @State private var remotes: [RcloneConfig.Remote]?
    @State private var loadError: String?
    @State private var testResults: [String: TestResult] = [:]
    @State private var confirmingDelete: RcloneConfig.Remote?
    @State private var isAdding = false
    @State private var justAdded: String?

    enum TestResult: Equatable {
        case running
        case ok(Int)
        case failed(String)
    }

    var body: some View {
        Group {
            if isAdding {
                AddRemoteFlow(existingNames: Set((remotes ?? []).map(\.name))) { added in
                    isAdding = false
                    if let added { justAdded = added }
                    Task { await reload() }
                }
            } else {
                remoteList
            }
        }
        .frame(width: 580, height: 600)
        .task { await reload() }
    }

    private var remoteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cloud Remotes").font(.headline)
                Spacer()
                Button {
                    isAdding = true
                } label: {
                    Label("Add Remote…", systemImage: "plus")
                }
            }
            .padding(20)
            Divider()

            if let loadError {
                message(icon: "exclamationmark.triangle", text: loadError)
            } else if let remotes, remotes.isEmpty {
                message(icon: "cloud", text: "No remotes yet. Add Google Drive, Dropbox, OneDrive, S3 or any other storage rclone supports.")
            } else if let remotes {
                List(remotes) { remote in
                    row(remote)
                }
                .listStyle(.inset)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Text("Stored in your rclone config, so they also work with rclone in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onClose(justAdded) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .confirmationDialog("Delete “\(confirmingDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }
        )) {
            Button("Delete Remote", role: .destructive) {
                if let remote = confirmingDelete { Task { await delete(remote) } }
            }
        } message: {
            Text("This removes the remote and its saved sign-in from your rclone config. Files in the cloud aren't touched.")
        }
    }

    private func row(_ remote: RcloneConfig.Remote) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(remote.name)
                Group {
                    switch testResults[remote.name] {
                    case .running: Text("Testing…")
                    case .ok(let count): Text("Connected — \(count) item\(count == 1 ? "" : "s") at the top level").foregroundStyle(.green)
                    case .failed(let reason): Text(reason).foregroundStyle(.red).lineLimit(2)
                    case nil: Text(remote.type)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Test") { Task { await test(remote) } }
                .disabled(testResults[remote.name] == .running)
            Button {
                confirmingDelete = remote
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete remote")
        }
        .padding(.vertical, 4)
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        do {
            remotes = try await RcloneConfig.remotes()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func test(_ remote: RcloneConfig.Remote) async {
        testResults[remote.name] = .running
        do {
            testResults[remote.name] = .ok(try await RcloneConfig.test(remote.name))
        } catch {
            testResults[remote.name] = .failed(error.localizedDescription)
        }
    }

    private func delete(_ remote: RcloneConfig.Remote) async {
        do {
            try await RcloneConfig.delete(remote.name)
            testResults[remote.name] = nil
        } catch {
            loadError = error.localizedDescription
        }
        await reload()
    }
}

/// Choosing a provider, filling in its settings, then answering whatever
/// rclone asks next until it says the remote is ready.
private struct AddRemoteFlow: View {
    let existingNames: Set<String>
    var onFinish: (String?) -> Void

    private enum Phase {
        case loading
        case choosing
        case configuring(RcloneConfig.Provider)
        case working(String)
        case question(RcloneConfig.Step)
        case signingIn
        case done
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var providers: [RcloneConfig.Provider] = []
    @State private var search = ""
    @State private var name = ""
    @State private var values: [String: String] = [:]
    @State private var showAdvanced = false
    @State private var answer = ""
    @State private var signInLink: URL?
    /// Set once `config create` has run, so cancelling can remove the
    /// half-configured remote rather than leave it in the user's config.
    @State private var createdName: String?
    @State private var runningProcess: Process?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .choosing:
                providerPicker
            case .configuring(let provider):
                configureForm(provider)
            case .working(let text):
                status(icon: nil, title: text, detail: nil)
            case .question(let step):
                questionView(step)
            case .signingIn:
                signInView
            case .done:
                status(icon: "checkmark.circle.fill", title: "“\(createdName ?? name)” is ready", detail: "It's now in the Remote list for cloud endpoints.")
            case .failed(let reason):
                status(icon: "exclamationmark.triangle.fill", title: "Couldn't add the remote", detail: reason)
            }
        }
        .task {
            do {
                providers = try await RcloneConfig.providers()
                phase = .choosing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Choosing

    private var filteredProviders: [RcloneConfig.Provider] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return providers }
        return providers.filter { $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "Add Remote", back: nil)
            TextField("Search providers", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
            List {
                let matches = filteredProviders
                let popular = RcloneConfig.popular.compactMap { name in matches.first { $0.name == name } }
                if !popular.isEmpty {
                    Section("Popular") { ForEach(popular) { providerRow($0) } }
                }
                Section(popular.isEmpty ? "Providers" : "All providers") {
                    ForEach(matches.filter { !RcloneConfig.popular.contains($0.name) }) { providerRow($0) }
                }
            }
            .listStyle(.inset)
            footer {
                Button("Cancel") { onFinish(nil) }
            }
        }
    }

    private func providerRow(_ provider: RcloneConfig.Provider) -> some View {
        Button {
            name = uniqueName(for: provider)
            values = [:]
            showAdvanced = false
            phase = .configuring(provider)
        } label: {
            HStack {
                Text(provider.title)
                Spacer()
                Text(provider.name).font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func uniqueName(for provider: RcloneConfig.Provider) -> String {
        let base = provider.name.replacingOccurrences(of: " ", with: "-")
        var candidate = base
        var n = 2
        while existingNames.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: Configuring

    private func visibleOptions(_ provider: RcloneConfig.Provider) -> [RcloneConfig.Option] {
        let selected = values["provider"] ?? ""
        return provider.options.filter { option in
            !option.hiddenFromConfigurator && (showAdvanced || !option.advanced) && option.appliesTo(provider: selected)
        }
    }

    private func nameProblem() -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give the remote a name." }
        if !RcloneConfig.isValidName(name) { return "Names can use letters, numbers, spaces and _ - . + @, and can't start with - or a space." }
        if existingNames.contains(name) { return "There's already a remote called “\(name)”." }
        return nil
    }

    private func missingRequired(_ provider: RcloneConfig.Provider) -> [RcloneConfig.Option] {
        visibleOptions(provider).filter { $0.required && ($0.defaultString.isEmpty) && (values[$0.name] ?? "").isEmpty }
    }

    private func configureForm(_ provider: RcloneConfig.Provider) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: provider.title, back: { phase = .choosing })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.subheadline.weight(.medium))
                        TextField("my-\(provider.name)", text: $name)
                            .textFieldStyle(.roundedBorder)
                        if let problem = nameProblem() {
                            Text(problem).font(.caption).foregroundStyle(.red)
                        }
                    }
                    let options = visibleOptions(provider)
                    if options.isEmpty {
                        Text("Nothing to fill in here. rclone will ask anything else it needs next.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(options) { option in
                        OptionField(option: option, value: binding(for: option.name), providerFilter: values["provider"] ?? "")
                    }
                    if provider.options.contains(where: { $0.advanced && !$0.hiddenFromConfigurator }) {
                        Toggle("Show advanced settings", isOn: $showAdvanced)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if provider.options.contains(where: { $0.name == "token" }) {
                        Label("After this, your browser opens so you can sign in to \(provider.title). Leave the client ID and secret empty to use rclone's defaults.", systemImage: "safari")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            footer {
                Button("Cancel") { onFinish(nil) }
                Spacer()
                Button("Add Remote") { Task { await create(provider) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem() != nil || !missingRequired(provider).isEmpty)
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    // MARK: Following rclone's questions

    private func questionView(_ step: RcloneConfig.Step) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: "One more thing", back: nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let option = step.option {
                        Text(option.help).fixedSize(horizontal: false, vertical: true)
                        OptionField(option: option, value: $answer, providerFilter: "", showsHelp: false)
                    }
                    if !step.error.isEmpty {
                        Label(step.error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            footer {
                Button("Cancel") { Task { await cancel() } }
                Spacer()
                Button("Continue") { Task { await submit(step) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var signInView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: "Sign in", back: nil)
            VStack(spacing: 14) {
                ProgressView()
                Text("Finish signing in in your browser.").font(.headline)
                Text("rclone opened a sign-in page. Once you allow access there, this continues by itself.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let signInLink {
                    Link("Browser didn't open? Open the sign-in page", destination: signInLink)
                        .font(.callout)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer {
                Button("Cancel") { Task { await cancel() } }
                Spacer()
            }
        }
    }

    private func status(icon: String?, title: String, detail: String?) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 40))
                        .foregroundStyle(icon.contains("checkmark") ? Color.green : Color.orange)
                } else {
                    ProgressView()
                }
                Text(title).font(.headline).multilineTextAlignment(.center)
                if let detail {
                    Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if icon != nil {
                footer {
                    Spacer()
                    Button("Done") { onFinish(isDone ? createdName : nil) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    // MARK: Layout helpers

    private func header(title: String, back: (() -> Void)?) -> some View {
        HStack {
            if let back {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
            }
            Text(title).font(.headline)
            Spacer()
        }
        .padding(20)
    }

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack { content() }.padding(16)
        }
    }

    // MARK: Actions

    private func create(_ provider: RcloneConfig.Provider) async {
        // Only what the user actually set: anything left at its default is
        // rclone's to decide, and passing it would pin today's default.
        let options = Dictionary(uniqueKeysWithValues: provider.options.map { ($0.name, $0) })
        let changed = values.filter { key, value in
            guard let option = options[key] else { return false }
            return !value.isEmpty && value != option.defaultString
        }
        let passwords = Set(changed.keys.filter { options[$0]?.isPassword == true })
        phase = .working("Adding “\(name)”…")
        do {
            let step = try await RcloneConfig.create(name: name, type: provider.name, values: changed, passwords: passwords,
                                                     onProgress: progress, onStart: started)
            createdName = name
            await handle(step)
        } catch {
            createdName = name
            await failAndCleanUp(error.localizedDescription)
        }
    }

    private func submit(_ step: RcloneConfig.Step) async {
        guard let createdName else { return }
        let isPassword = step.option?.isPassword ?? false
        let result = answer.isEmpty ? (step.option?.defaultString ?? "") : answer
        phase = .working("Continuing…")
        do {
            await handle(try await RcloneConfig.answer(name: createdName, state: step.state, result: result, isPassword: isPassword,
                                                       onProgress: progress, onStart: started))
        } catch {
            await failAndCleanUp(error.localizedDescription)
        }
    }

    private func handle(_ step: RcloneConfig.Step) async {
        if step.isFinished {
            phase = .done
            return
        }
        // "Use a web browser to sign in?" — yes: this is a Mac with one, and
        // the other answer means running rclone on a second machine.
        if step.option?.name == "config_is_local", let createdName {
            signInLink = nil
            phase = .signingIn
            do {
                await handle(try await RcloneConfig.answer(name: createdName, state: step.state, result: "true", isPassword: false,
                                                           onProgress: progress, onStart: started))
            } catch {
                await failAndCleanUp(error.localizedDescription)
            }
            return
        }
        answer = step.option?.defaultString ?? ""
        phase = .question(step)
    }

    // Called from rclone's output handler, off the main actor, so these only
    // hop to it to touch state.
    nonisolated private func progress(_ line: String) {
        if let link = RcloneConfig.signInLink(in: line) {
            Task { @MainActor in signInLink = link }
        }
    }

    nonisolated private func started(_ process: Process) {
        Task { @MainActor in runningProcess = process }
    }

    private func cancel() async {
        if let runningProcess, runningProcess.isRunning { runningProcess.terminate() }
        if let createdName { try? await RcloneConfig.delete(createdName) }
        onFinish(nil)
    }

    private func failAndCleanUp(_ reason: String) async {
        if case .signingIn = phase, runningProcess?.terminationReason == .uncaughtSignal {
            return  // cancelled by the user; cancel() handles the rest
        }
        if let createdName { try? await RcloneConfig.delete(createdName) }
        createdName = nil
        phase = .failed(reason)
    }
}

/// One rclone setting as a form control, chosen from its type: a switch for
/// yes/no, a menu for a fixed list of choices, suggestions for a free field
/// that has common values, a secure field for passwords.
private struct OptionField: View {
    let option: RcloneConfig.Option
    @Binding var value: String
    let providerFilter: String
    var showsHelp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if option.type == "bool" {
                Toggle(isOn: Binding(
                    get: { (value.isEmpty ? option.defaultString : value) == "true" },
                    set: { value = $0 ? "true" : "false" }
                )) {
                    label
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            } else {
                label
                control
            }
            if showsHelp, !option.summary.isEmpty {
                Text(option.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(option.help)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            if option.required && option.defaultString.isEmpty {
                Text("*").foregroundStyle(.red)
            }
        }
    }

    /// "access_key_id" → "Access key id".
    private var title: String {
        let words = option.name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    @ViewBuilder
    private var control: some View {
        let examples = option.examples(for: providerFilter)
        if !examples.isEmpty && option.exclusive {
            Picker("", selection: $value) {
                if !option.required || !option.defaultString.isEmpty {
                    Text(option.defaultString.isEmpty ? "Default" : "Default (\(option.defaultString))").tag("")
                }
                ForEach(examples, id: \.value) { example in
                    Text(describe(example)).tag(example.value)
                }
            }
            .labelsHidden()
        } else if option.isPassword || option.sensitive {
            SecureField(option.defaultString.isEmpty ? "" : option.defaultString, text: $value)
                .textFieldStyle(.roundedBorder)
        } else {
            HStack(spacing: 6) {
                TextField(option.defaultString, text: $value)
                    .textFieldStyle(.roundedBorder)
                if !examples.isEmpty {
                    Menu {
                        ForEach(examples, id: \.value) { example in
                            Button(describe(example)) { value = example.value }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Common values")
                }
            }
        }
    }

    private func describe(_ example: RcloneConfig.Example) -> String {
        let help = example.help.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if example.value.isEmpty { return help.isEmpty ? "(empty)" : help }
        return help.isEmpty || help == example.value ? example.value : "\(example.value) — \(help)"
    }
}

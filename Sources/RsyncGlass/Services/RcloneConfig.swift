import Foundation

/// Setting up rclone remotes from inside the app, instead of `rclone config`
/// in Terminal. Everything is driven by rclone's own descriptions: the
/// provider list and each provider's settings come from `rclone config
/// providers`, and the follow-up questions some providers ask (Google
/// Drive's shared-drive choice, browser sign-in) come from rclone's
/// non-interactive config protocol — so every backend rclone supports works
/// without the app knowing about any of them.
enum RcloneConfig {

    // MARK: - Provider descriptions

    struct Provider: Decodable, Identifiable, Hashable {
        let name: String
        let description: String
        let hide: Bool
        let options: [Option]
        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name = "Name", description = "Description", hide = "Hide", options = "Options"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = (try? c.decode(String.self, forKey: .description)) ?? name
            hide = ((try? c.decode(Int.self, forKey: .hide)) ?? 0) != 0
            options = (try? c.decode([Option].self, forKey: .options)) ?? []
        }

        /// A short name for lists. S3's description names fifty providers.
        var title: String {
            let firstClause = description.components(separatedBy: " including").first ?? description
            return firstClause.count > 48 ? String(firstClause.prefix(45)) + "…" : firstClause
        }

        static func == (a: Provider, b: Provider) -> Bool { a.name == b.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    struct Example: Decodable, Hashable {
        let value: String
        let help: String
        let provider: String

        enum CodingKeys: String, CodingKey { case value = "Value", help = "Help", provider = "Provider" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = (try? c.decode(String.self, forKey: .value)) ?? ""
            help = (try? c.decode(String.self, forKey: .help)) ?? ""
            provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        }
    }

    struct Option: Decodable, Identifiable, Hashable {
        let name: String
        let help: String
        let type: String
        let defaultString: String
        let required: Bool
        let isPassword: Bool
        /// Secret but stored as-is (API keys, client secrets), unlike a
        /// password, which rclone obscures. Masked on screen either way.
        let sensitive: Bool
        let advanced: Bool
        let exclusive: Bool
        let hide: Int
        let provider: String
        let examples: [Example]
        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name = "Name", help = "Help", type = "Type", defaultString = "DefaultStr", required = "Required",
                 isPassword = "IsPassword", sensitive = "Sensitive", advanced = "Advanced", exclusive = "Exclusive", hide = "Hide",
                 provider = "Provider", examples = "Examples"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            help = (try? c.decode(String.self, forKey: .help)) ?? ""
            type = (try? c.decode(String.self, forKey: .type)) ?? "string"
            defaultString = (try? c.decode(String.self, forKey: .defaultString)) ?? ""
            required = (try? c.decode(Bool.self, forKey: .required)) ?? false
            isPassword = (try? c.decode(Bool.self, forKey: .isPassword)) ?? false
            sensitive = (try? c.decode(Bool.self, forKey: .sensitive)) ?? false
            advanced = (try? c.decode(Bool.self, forKey: .advanced)) ?? false
            exclusive = (try? c.decode(Bool.self, forKey: .exclusive)) ?? false
            hide = (try? c.decode(Int.self, forKey: .hide)) ?? 0
            provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
            examples = (try? c.decode([Example].self, forKey: .examples)) ?? []
        }

        /// rclone's own configurator skips these (Hide has the "hide from
        /// configurator" bit set).
        var hiddenFromConfigurator: Bool { hide & 2 != 0 }

        /// First paragraph of the help, which is the summary; the rest is
        /// usually detail better left to rclone's docs.
        var summary: String {
            help.components(separatedBy: "\n\n").first?.replacingOccurrences(of: "\n", with: " ") ?? ""
        }

        func appliesTo(provider selected: String) -> Bool {
            RcloneConfig.providerFilter(provider, matches: selected)
        }

        func examples(for selected: String) -> [Example] {
            examples.filter { RcloneConfig.providerFilter($0.provider, matches: selected) }
        }
    }

    /// Some settings only apply to some S3-style providers: "AWS,Minio"
    /// means just those, "!AWS" everything but. Empty means all.
    static func providerFilter(_ filter: String, matches selected: String) -> Bool {
        guard !filter.isEmpty else { return true }
        let negated = filter.hasPrefix("!")
        let names = filter.dropFirst(negated ? 1 : 0).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let listed = names.contains(selected)
        return negated ? !listed : listed
    }

    /// The providers people usually want, listed first.
    static let popular = ["drive", "dropbox", "onedrive", "iclouddrive", "s3", "b2", "box", "pcloud", "mega", "protondrive", "webdav", "sftp", "smb", "ftp"]

    static func providers() async throws -> [Provider] {
        let result = try await run(["config", "providers"])
        guard result.exitCode == 0 else { throw ConfigError.failed(result.stderr) }
        return try JSONDecoder().decode([Provider].self, from: Data(result.stdout.utf8)).filter { !$0.hide }
    }

    // MARK: - Remotes

    struct Remote: Identifiable, Hashable {
        let name: String
        let type: String
        var id: String { name }
    }

    static func remotes() async throws -> [Remote] {
        let result = try await run(["listremotes", "--long"])
        guard result.exitCode == 0 else { throw ConfigError.failed(result.stderr) }
        return result.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            // "name:   type" — names may contain spaces, so split on the last colon.
            guard let colon = line.lastIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let type = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : Remote(name: name, type: type)
        }
    }

    static func delete(_ name: String) async throws {
        let result = try await run(["config", "delete", name])
        guard result.exitCode == 0 else { throw ConfigError.failed(result.stderr) }
    }

    /// Lists the remote's top level, which is the cheapest thing that proves
    /// the credentials work. Returns how many entries it saw.
    static func test(_ name: String) async throws -> Int {
        let result = try await run(["lsf", name + ":", "--max-depth", "1", "--contimeout", "15s", "--timeout", "30s", "--low-level-retries", "1", "--retries", "1"])
        guard result.exitCode == 0 else { throw ConfigError.failed(result.stderr) }
        return result.stdout.split(whereSeparator: \.isNewline).count
    }

    /// rclone's rules: letters, digits, "_-.+@" and spaces, not starting with
    /// "-" or a space, not ending with a space.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, let last = name.last, first != "-", first != " ", last != " " else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "_-.+@ ".contains($0) }
    }

    // MARK: - Creating a remote, step by step

    /// Where setup stands after a call: finished, or a question to answer.
    struct Step: Decodable {
        let state: String
        let option: Option?
        let error: String

        enum CodingKeys: String, CodingKey { case state = "State", option = "Option", error = "Error" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = (try? c.decode(String.self, forKey: .state)) ?? ""
            option = try? c.decode(Option.self, forKey: .option)
            error = (try? c.decode(String.self, forKey: .error)) ?? ""
        }

        var isFinished: Bool { option == nil && state.isEmpty }
    }

    /// Creates the remote with the given settings. Passwords are obscured
    /// first (over stdin) and passed pre-obscured, so the command line only
    /// ever holds the obscured form — the same form rclone.conf stores.
    static func create(name: String, type: String, values: [String: String], passwords: Set<String>, onProgress: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws -> Step {
        var args = ["config", "create", name, type]
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            args.append("\(key)=\(passwords.contains(key) ? try await obscure(value) : value)")
        }
        args.append(contentsOf: ["--non-interactive", "--no-obscure"])
        return try await step(args, onProgress: onProgress, onStart: onStart)
    }

    static func answer(name: String, state: String, result: String, isPassword: Bool, onProgress: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws -> Step {
        let value = isPassword && !result.isEmpty ? try await obscure(result) : result
        return try await step(["config", "update", name, "--continue", "--state", state, "--result", value, "--non-interactive", "--no-obscure"],
                              onProgress: onProgress, onStart: onStart)
    }

    /// Pulls a sign-in link out of rclone's output, for when the browser
    /// doesn't open by itself.
    static func signInLink(in line: String) -> URL? {
        guard let range = line.range(of: #"https?://127\.0\.0\.1:\d+/\S*"#, options: .regularExpression) else { return nil }
        return URL(string: String(line[range]))
    }

    enum ConfigError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let detail):
                // rclone prefixes lines with a timestamp and level; the message is what matters.
                let lines = detail.split(whereSeparator: \.isNewline).map { line -> String in
                    let text = String(line)
                    if let range = text.range(of: #"(ERROR|NOTICE|CRITICAL|Failed)\s*:?\s*"#, options: .regularExpression) {
                        return String(text[range.upperBound...])
                    }
                    return text
                }
                return lines.last(where: { !$0.isEmpty }) ?? "rclone failed"
            }
        }
    }

    // MARK: - Running rclone

    private static func run(_ args: [String]) async throws -> ProcessResult {
        guard let rclone = CommandLocator.rclone else { throw RcloneEngine.EngineError.missing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclone)
        process.arguments = args + ["--ask-password=false"]
        return try await ProcessRunner.run(process)
    }

    /// One config call. Streams stderr as it arrives: a browser sign-in
    /// blocks inside this call until the user finishes, and the sign-in
    /// link it prints is needed while it's still waiting.
    private static func step(_ args: [String], onProgress: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws -> Step {
        guard let rclone = CommandLocator.rclone else { throw RcloneEngine.EngineError.missing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclone)
        process.arguments = args + ["--ask-password=false"]
        let errPipe = Pipe()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) { onProgress(String(line)) }
        }
        process.standardError = errPipe
        let result = try await ProcessRunner.run(process, onStart: onStart, keepingStderr: true)
        errPipe.fileHandleForReading.readabilityHandler = nil
        guard let step = try? JSONDecoder().decode(Step.self, from: Data(result.stdout.utf8)) else {
            throw ConfigError.failed(result.stdout.isEmpty ? "rclone stopped before finishing setup" : result.stdout)
        }
        return step
    }

    static func obscure(_ secret: String) async throws -> String {
        guard let rclone = CommandLocator.rclone else { throw RcloneEngine.EngineError.missing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclone)
        process.arguments = ["obscure", "-"]
        let input = Pipe()
        process.standardInput = input
        async let result = ProcessRunner.run(process)
        input.fileHandleForWriting.write(Data(secret.utf8))
        try? input.fileHandleForWriting.close()
        let output = try await result
        let obscured = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.exitCode == 0, !obscured.isEmpty else { throw ConfigError.failed(output.stderr) }
        return obscured
    }
}

import Foundation

/// macOS ships an ancient rsync 2.6.9 (protocol 29) for licensing reasons;
/// Homebrew installs a modern 3.x build. We detect which one we've got so we
/// don't pass flags the stock binary doesn't understand.
enum RsyncCapabilities {
    static let version: (major: Int, minor: Int) = detect()

    /// --info=progress2 requires rsync 3.1+.
    static var supportsInfoProgress2: Bool {
        version.major > 3 || (version.major == 3 && version.minor >= 1)
    }

    /// --protect-args (-s) requires rsync 3.0+.
    static var supportsProtectArgs: Bool {
        version.major >= 3
    }

    private static func detect() -> (major: Int, minor: Int) {
        guard let path = CommandLocator.rsync else { return (0, 0) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (0, 0)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let versionRange = text.range(of: "version ") else { return (0, 0) }
        let rest = text[versionRange.upperBound...]
        let token = rest.prefix(while: { $0.isNumber || $0 == "." })
        let comps = token.split(separator: ".").compactMap { Int($0) }
        return (comps.first ?? 0, comps.count > 1 ? comps[1] : 0)
    }
}

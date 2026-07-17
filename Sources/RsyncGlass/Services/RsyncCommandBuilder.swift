import Foundation

enum RsyncCommandBuilderError: LocalizedError {
    case missingRsync
    case bothEndpointsRemote

    var errorDescription: String? {
        switch self {
        case .missingRsync:
            return "Could not find `rsync` on this Mac. Install it via Homebrew: brew install rsync"
        case .bothEndpointsRemote:
            return "rsync can't transfer directly between two remote hosts. At least one side must be local to this Mac."
        }
    }
}

enum RsyncCommandBuilder {
    /// Builds one rsync Process.
    /// - itemNames: non-nil to transfer only these top-level entries of a directory source (parallel split mode);
    ///              nil to transfer the whole source path as a single unit (single-stream mode).
    /// - sourceIsDirectory: affects trailing-slash "copy contents into target" semantics for whole-path transfers.
    static func buildProcess(
        source: Endpoint,
        target: Endpoint,
        itemNames: [String]?,
        sourceIsDirectory: Bool,
        options: RsyncOptions
    ) throws -> Process {
        guard let rsyncPath = CommandLocator.rsync else { throw RsyncCommandBuilderError.missingRsync }
        guard !(source.isRemote && target.isRemote) else { throw RsyncCommandBuilderError.bothEndpointsRemote }

        var args = options.baseFlags()
        args.append(RsyncCapabilities.supportsInfoProgress2 ? "--info=progress2" : "--progress")

        let remoteEndpoint: Endpoint? = source.isRemote ? source : (target.isRemote ? target : nil)
        if let remoteEndpoint {
            if RsyncCapabilities.supportsProtectArgs {
                args.append("-s")
            }
            let rsh = try SSHConnectionBuilder.rshCommand(for: remoteEndpoint)
            args.append(contentsOf: ["-e", rsh])
        }

        if let itemNames, !itemNames.isEmpty {
            for name in itemNames {
                if source.isRemote {
                    args.append(source.remoteSpec(path: PathUtilities.join(source.remotePath, name)))
                } else {
                    args.append(PathUtilities.join(source.localPath, name))
                }
            }
        } else {
            let path = sourceIsDirectory ? PathUtilities.withTrailingSlash(source.path) : source.path
            args.append(source.isRemote ? source.remoteSpec(path: path) : path)
        }

        if target.isRemote {
            args.append(target.remoteSpec(path: PathUtilities.withTrailingSlash(target.remotePath)))
        } else {
            args.append(PathUtilities.withTrailingSlash(target.localPath))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsyncPath)
        process.arguments = args

        if let remoteEndpoint, remoteEndpoint.authMethod == .password {
            var environment = ProcessInfo.processInfo.environment
            environment["SSHPASS"] = remoteEndpoint.password
            process.environment = environment
        }

        return process
    }
}

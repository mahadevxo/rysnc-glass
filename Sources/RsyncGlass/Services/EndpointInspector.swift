import Foundation

enum EndpointInspectorError: LocalizedError {
    case pathNotFound(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        }
    }
}

enum EndpointInspector {
    /// Whether the endpoint's path refers to a directory. Throws if the path
    /// doesn't exist (local) or the connection/check fails (remote).
    static func isDirectory(_ endpoint: Endpoint) async throws -> Bool {
        if endpoint.isRemote {
            let quoted = PathUtilities.shellQuote(endpoint.remotePath)
            let cmd = "test -d \(quoted) && echo IS_DIR || (test -e \(quoted) && echo IS_FILE || echo MISSING)"
            let process = try SSHConnectionBuilder.makeProcess(for: endpoint, remoteCommand: cmd)
            let result = try await ProcessRunner.run(process)
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.contains("MISSING") {
                throw EndpointInspectorError.pathNotFound(endpoint.remotePath)
            }
            return output.contains("IS_DIR")
        } else {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: endpoint.localPath, isDirectory: &isDir)
            guard exists else { throw EndpointInspectorError.pathNotFound(endpoint.localPath) }
            return isDir.boolValue
        }
    }

    /// Size in bytes if the endpoint's path is a regular file, nil if it's
    /// a directory. Only needed for remote sources.
    static func fileSize(_ endpoint: Endpoint) async throws -> Int64? {
        let quoted = PathUtilities.shellQuote(endpoint.path)
        if endpoint.isRemote {
            let process = try SSHConnectionBuilder.makeProcess(for: endpoint, remoteCommand: "if [ -f \(quoted) ]; then wc -c < \(quoted); fi")
            let result = try await ProcessRunner.run(process)
            return Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: endpoint.localPath)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}

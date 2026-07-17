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
}

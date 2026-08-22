import Foundation

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ProcessRunner {
    /// Runs a fully-configured Process to completion and captures its output.
    /// - onStart: called with the process once it's running, so a caller can
    ///   keep a handle on it and terminate it early. Indexing a large remote
    ///   tree takes real time, and without this a cancel can't interrupt it.
    static func run(_ process: Process, onStart: ((Process) -> Void)? = nil) async throws -> ProcessResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = ProcessResult(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                )
                continuation.resume(returning: result)
            }
            do {
                try process.run()
                onStart?(process)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

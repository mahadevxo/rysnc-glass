import Foundation

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ProcessRunner {
    /// Runs a fully-configured Process to completion and captures its output.
    static func run(_ process: Process) async throws -> ProcessResult {
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
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

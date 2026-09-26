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

        // Drain both pipes while the process runs, not after it exits: a pipe
        // holds 64KB, and a process that fills it blocks on the write and
        // never exits — so waiting for exit before reading would hang for
        // good on any large output, like a folder with thousands of entries.
        let drained = DispatchGroup()
        let collected = Collected()
        for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
            drained.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.store(data, isStdout: isStdout)
                drained.leave()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                drained.notify(queue: .global()) {
                    continuation.resume(returning: ProcessResult(
                        stdout: String(data: collected.stdout, encoding: .utf8) ?? "",
                        stderr: String(data: collected.stderr, encoding: .utf8) ?? "",
                        exitCode: proc.terminationStatus
                    ))
                }
            }
            do {
                try process.run()
                onStart?(process)
            } catch {
                // The readers are blocked on pipes nothing will ever write
                // to; closing our write ends lets them see EOF and finish.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func store(_ data: Data, isStdout: Bool) {
        lock.withLock { if isStdout { out = data } else { err = data } }
    }

    var stdout: Data { lock.withLock { out } }
    var stderr: Data { lock.withLock { err } }
}

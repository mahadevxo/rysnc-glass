import Foundation

enum JobPhase: Equatable {
    case idle
    case planning
    case running
    case finished(success: Bool)
    case cancelled
}

@Observable
final class StreamState: Identifiable {
    let id: Int
    var itemNames: [String] = []
    var byteShare: Double = 0        // fraction of total bytes this stream is responsible for (0...1)
    var progressFraction: Double = 0 // 0...1, parsed from rsync --info=progress2 output
    var isRunning: Bool = false
    var exitCode: Int32?
    var currentFile: String = ""

    init(id: Int) {
        self.id = id
    }
}

@Observable
final class TransferState {
    var phase: JobPhase = .idle
    var streams: [StreamState] = []
    var logLines: [String] = []
    var statusMessage: String = ""

    var overallProgress: Double {
        guard !streams.isEmpty else { return 0 }
        return streams.reduce(0.0) { $0 + $1.progressFraction * $1.byteShare }
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 {
            logLines.removeFirst(logLines.count - 2000)
        }
    }

    func reset() {
        phase = .idle
        streams = []
        logLines = []
        statusMessage = ""
    }
}

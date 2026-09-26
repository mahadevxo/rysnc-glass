import Foundation

enum JobPhase: Equatable {
    case idle
    case planning
    case running
    case finished(success: Bool)
    case cancelled
}

/// Progress of one rsync process. Costs are in the same KB-equivalent units
/// SplitPlanner balances on, so a leg holding thousands of small files counts
/// as the work it actually is rather than as the handful of bytes it moves.
final class LegProgress {
    /// Indexed work this leg covers, or nil when the source couldn't be
    /// indexed — the leg then falls back to rsync's own byte percentage.
    let costKB: Double?
    var fraction: Double = 0
    var bytes: Int64 = 0
    /// Only reported as each file closes out, so the last count carries over
    /// between updates.
    private var checkedEntries = 0

    init(costKB: Double?) {
        self.costKB = costKB
    }

    /// - cumulativeBytes: true under --info=progress2, where the byte count
    ///   is the whole process's running total rather than the current file's.
    func apply(_ update: RsyncProgressUpdate, cumulativeBytes: Bool) {
        if let checked = update.checkedEntries { checkedEntries = checked }
        if cumulativeBytes { bytes = update.bytes }

        let next: Double
        if let costKB, costKB > 0 {
            // Bytes alone sit near 100% while rsync is still grinding through
            // a tail of small files; counting checked entries at their
            // per-entry cost keeps the bar moving through that tail too.
            let entryKB = Double(checkedEntries * SplitPlanner.perEntryCostKB)
            let byteKB = cumulativeBytes ? Double(bytes) / 1024 : 0
            next = (byteKB + entryKB) / costKB
        } else {
            next = Double(update.percent) / 100
        }
        // Never go backwards: resumed transfers skip up-to-date files without
        // counting their bytes, which can make one estimate briefly undercut
        // the last.
        fraction = max(fraction, min(next, 1))
    }
}

@Observable
final class StreamState: Identifiable {
    let id: Int
    var itemNames: [String] = []
    var workShare: Double = 0        // fraction of total estimated work this stream is responsible for (0...1), see SplitPlanner.cost
    var progressFraction: Double = 0 // 0...1, recomputed from this stream's legs as rsync reports progress
    var isRunning: Bool = false
    var exitCode: Int32?
    var currentFile: String = ""
    var itemsTotal: Int = 0          // remote-to-remote relay: total items assigned to this stream
    var itemsCompleted: Int = 0      // remote-to-remote relay: items fully relayed (downloaded, uploaded, and deleted from staging)
    var bytesTransferred: Int64 = 0
    var bytesPerSecond: Double = 0

    /// Sum of the costs of every leg this stream will run. A relay item
    /// contributes twice — once to download, once to upload.
    var totalCostKB: Double = 0
    /// Kept after they finish, not folded into running totals: rsync's last
    /// progress line can land just after its process exits, and it should
    /// still count.
    private var legs: [LegProgress] = []

    init(id: Int) {
        self.id = id
    }

    /// A pipelined relay runs two legs on one stream at once, so each leg
    /// reports into its own LegProgress rather than into shared fields.
    func beginLeg(costKB: Double?) -> LegProgress {
        let leg = LegProgress(costKB: costKB)
        legs.append(leg)
        return leg
    }

    func endLeg(_ leg: LegProgress, succeeded: Bool) {
        if succeeded { leg.fraction = 1 }
        recompute()
    }

    func recompute() {
        let done = legs.reduce(0.0) { $0 + ($1.costKB ?? 1) * $1.fraction }
        if totalCostKB > 0 {
            progressFraction = min(max(done / totalCostKB, progressFraction), 1)
        }
        bytesTransferred = legs.reduce(0) { $0 + $1.bytes }
    }
}

/// Rate of change of a monotonically growing value, over a trailing window.
struct RateWindow {
    let span: TimeInterval
    private var samples: [(time: TimeInterval, value: Double)] = []

    init(span: TimeInterval) {
        self.span = span
    }

    mutating func add(_ value: Double, at time: TimeInterval) {
        samples.append((time, value))
        samples.removeAll { time - $0.time > span }
    }

    /// Units per second, or nil until there are two samples far enough apart
    /// to say anything.
    var rate: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 0.5 else { return nil }
        return max(last.value - first.value, 0) / (last.time - first.time)
    }
}

@Observable
final class TransferState {
    var phase: JobPhase = .idle
    var streams: [StreamState] = []
    var logLines: [String] = []
    var statusMessage: String = ""

    var startedAt: Date?
    var finishedAt: Date?
    var bytesPerSecond: Double = 0
    /// Seconds left at the current pace, nil while there's no pace to go on.
    var secondsRemaining: Double?
    /// Ticks once a second while a job runs, so views showing elapsed time
    /// redraw without needing their own timer.
    var now = Date()

    var overallProgress: Double {
        guard !streams.isEmpty else { return 0 }
        return min(streams.reduce(0.0) { $0 + $1.progressFraction * $1.workShare }, 1)
    }

    var bytesTransferred: Int64 {
        streams.reduce(0) { $0 + $1.bytesTransferred }
    }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
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
        startedAt = nil
        finishedAt = nil
        bytesPerSecond = 0
        secondsRemaining = nil
        now = Date()
    }
}

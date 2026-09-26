import Foundation

/// One progress update from rsync's output.
struct RsyncProgressUpdate: Equatable {
    /// Cumulative bytes sent by this process so far. Only meaningful under
    /// --info=progress2 — plain --progress reports per-file byte counts.
    let bytes: Int64
    let percent: Int
    /// Entries rsync has finished checking (transferred or found up to date),
    /// from the "to-chk=X/Y" tail: Y entries known, X still to check. Only
    /// present on the update that closes out a file.
    let checkedEntries: Int?
}

enum RsyncProgressParser {
    // "     62,914,560  66%   39.32MB/s    0:00:01 (xfr#1, to-chk=3001/3005)"
    // The tail is "ir-chk" while incremental recursion is still discovering
    // files, and "xfer#"/"to-check" on rsync 2.x.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*([\d,]+)\s+(\d+)%\s+\S+/s\s+\S+(?:\s+\((?:xfr|xfer)#\d+,\s*(?:ir|to)-(?:chk|check)=(\d+)/(\d+)\))?"#
    )

    static func parse(_ line: String) -> RsyncProgressUpdate? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range),
              let bytesRange = Range(match.range(at: 1), in: line),
              let percentRange = Range(match.range(at: 2), in: line),
              let bytes = Int64(line[bytesRange].replacingOccurrences(of: ",", with: "")),
              let percent = Int(line[percentRange]) else { return nil }

        var checked: Int?
        if let remainingRange = Range(match.range(at: 3), in: line),
           let knownRange = Range(match.range(at: 4), in: line),
           let remaining = Int(line[remainingRange]),
           let known = Int(line[knownRange]) {
            checked = max(known - remaining, 0)
        }
        return RsyncProgressUpdate(bytes: bytes, percent: percent, checkedEntries: checked)
    }
}

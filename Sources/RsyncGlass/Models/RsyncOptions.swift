import Foundation

@Observable
final class RsyncOptions {
    var archive: Bool = true          // -a
    var compress: Bool = true         // -z
    var delete: Bool = false          // --delete
    var dryRun: Bool = false          // -n
    var resumePartial: Bool = true    // --partial, keeps partial files so a re-run resumes instead of restarting
    var verbose: Bool = true          // -v
    var excludePatterns: String = ""  // comma or newline separated
    var bandwidthLimitKBps: String = "" // --bwlimit, empty = unlimited
    var extraArgs: String = ""        // free-form additional flags
    var streamCount: Int = 1          // number of parallel rsync processes

    var excludeList: [String] {
        excludePatterns
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var extraArgList: [String] {
        extraArgs
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Base flags shared by every rsync invocation for this job. Excludes -e,
    /// the progress-reporting flag (chosen by RsyncCommandBuilder based on the
    /// detected rsync version), and source/dest.
    func baseFlags() -> [String] {
        var flags: [String] = []
        if archive { flags.append("-a") } else { flags.append(contentsOf: ["-r", "-l", "-p", "-t", "-g", "-o"]) }
        if compress { flags.append("-z") }
        if delete { flags.append("--delete") }
        if dryRun { flags.append("-n") }
        if resumePartial { flags.append("--partial") }
        flags.append(verbose ? "-v" : "-q")
        for pattern in excludeList {
            flags.append("--exclude=\(pattern)")
        }
        if let bw = Int(bandwidthLimitKBps.trimmingCharacters(in: .whitespaces)), bw > 0 {
            flags.append("--bwlimit=\(bw)")
        }
        flags.append(contentsOf: extraArgList)
        return flags
    }
}

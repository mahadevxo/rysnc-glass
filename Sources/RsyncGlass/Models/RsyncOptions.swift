import Foundation

/// How fast the link to the remote side is, which decides whether rsync's
/// bandwidth-saving features pay for themselves.
/// What a remote-to-remote transfer does when the source server can't send
/// straight to the target.
enum RemoteFallback: String, CaseIterable, Identifiable {
    case rcloneStream = "Stream with rclone"
    case rsyncRelay = "Relay with rsync"
    var id: String { rawValue }
}

enum NetworkProfile: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case localNetwork = "Local network"
    case internet = "Internet"
    var id: String { rawValue }
}

@Observable
final class RsyncOptions {
    var archive: Bool = true          // -a
    var network: NetworkProfile = .automatic // local network: no compression; internet: -z
    var delete: Bool = false          // --delete
    var dryRun: Bool = false          // -n
    var resumePartial: Bool = true    // --partial, keeps partial files so a re-run resumes instead of restarting
    var verbose: Bool = true          // -v
    var excludePatterns: String = ""  // comma or newline separated
    var bandwidthLimitKBps: String = "" // --bwlimit, empty = unlimited
    var extraArgs: String = ""        // free-form additional flags
    var streamCount: Int = 1          // number of parallel rsync processes
    var directServerToServer: Bool = true // remote-to-remote: have the source rsync straight to the target when it can reach it
    var remoteFallback: RemoteFallback = .rcloneStream
    var pipelineRelayLegs: Bool = false // remote-to-remote only: overlap each item's upload with the next item's download

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

    /// Whether a transfer involving `host` (nil: both sides on this Mac)
    /// should be tuned for a fast local link.
    func isLocalNetwork(host: String?) -> Bool {
        switch network {
        case .localNetwork: return true
        case .internet: return false
        case .automatic: return host.map(NetworkClassifier.isLocal(host:)) ?? true
        }
    }

    /// Base flags shared by every rsync invocation for this job. Excludes -e,
    /// the progress-reporting flag (chosen by RsyncCommandBuilder based on the
    /// detected rsync version), and source/dest.
    ///
    /// - onLocalNetwork: a fast link, where compression costs more CPU time
    ///   than the bandwidth it saves. Delta transfer stays on even so (no
    ///   -W): it's what lets --partial resume an interrupted file instead of
    ///   resending all of it, and it only costs anything when an older copy
    ///   of a file is already on the target.
    func baseFlags(onLocalNetwork: Bool = false) -> [String] {
        var flags: [String] = []
        if archive { flags.append("-a") } else { flags.append(contentsOf: ["-r", "-l", "-p", "-t", "-g", "-o"]) }
        if !onLocalNetwork { flags.append("-z") }
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

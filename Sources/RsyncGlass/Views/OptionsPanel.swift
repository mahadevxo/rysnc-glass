import SwiftUI

struct OptionsPanel: View {
    @Bindable var options: RsyncOptions
    var isRemoteToRemote: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Options")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Toggle("Archive mode", isOn: $options.archive)
                    Toggle("Delete extraneous files on target", isOn: $options.delete)
                }
                GridRow {
                    Toggle("Dry run (preview only)", isOn: $options.dryRun)
                    Toggle("Verbose logging", isOn: $options.verbose)
                }
                GridRow {
                    Toggle("Resume interrupted transfers", isOn: $options.resumePartial)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                Picker("Network", selection: $options.network) {
                    ForEach(NetworkProfile.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Text(networkCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Bandwidth limit")
                TextField("unlimited", text: $options.bandwidthLimitKBps)
                    .fieldStyle()
                    .frame(width: 90)
                Text("KB/s")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Exclude patterns").font(.caption).foregroundStyle(.secondary)
                TextField("comma-separated, e.g. .DS_Store, *.tmp", text: $options.excludePatterns)
                    .fieldStyle()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Extra rsync flags").font(.caption).foregroundStyle(.secondary)
                TextField("space-separated, e.g. --exclude-from=list.txt", text: $options.extraArgs)
                    .fieldStyle()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Parallel streams")
                    Stepper(value: $options.streamCount, in: 1...16) {
                        Text("\(options.streamCount)")
                            .monospacedDigit()
                            .frame(width: 24)
                    }
                }
                Text("Splits the source's top-level items into \(options.streamCount) size-balanced group\(options.streamCount == 1 ? "" : "s") transferred over separate connections at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isRemoteToRemote {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Transfer server-to-server directly when possible", isOn: $options.directServerToServer)
                        .toggleStyle(.switch)
                    Text(options.directServerToServer
                         ? "The source server sends straight to the target, so the data never passes through this Mac. It logs in to the target with your key through a temporary forwarded agent, for this transfer only. If it can't reach the target, the transfer is routed through this Mac instead."
                         : "Always route the data through this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Through this Mac", selection: $options.remoteFallback) {
                        ForEach(RemoteFallback.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    Text(options.remoteFallback == .rcloneStream
                         ? "Streams through this Mac's memory with nothing staged on disk. Changed files are sent whole, and permissions and ownership aren't carried over."
                         : "rsync keeps permissions and ownership and sends only the changed parts of files, but each item is staged on this Mac's disk on the way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if options.remoteFallback == .rsyncRelay {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Overlap upload with next download (relay)", isOn: $options.pipelineRelayLegs)
                            .toggleStyle(.switch)
                        Text(options.pipelineRelayLegs
                             ? "Faster — while one item uploads to the target, the next item is already downloading. Uses roughly double the local disk per stream at any moment."
                             : "One item at a time per stream: fully downloaded, then uploaded, then deleted from local staging before starting the next. Lowest disk use — lets a transfer larger than this Mac's free space complete.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var networkCaption: String {
        switch options.network {
        case .automatic:
            return "Picks per host: private addresses (192.168.x, 10.x, .local…) get local-network tuning, everything else internet tuning."
        case .localNetwork:
            return "No compression — on a fast link it costs more CPU time than the bandwidth it saves, especially for photos, video and archives."
        case .internet:
            return "Compresses data in transit, to make the most of a slower link."
        }
    }
}

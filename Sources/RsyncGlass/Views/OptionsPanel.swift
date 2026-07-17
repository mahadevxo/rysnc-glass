import SwiftUI

struct OptionsPanel: View {
    @Bindable var options: RsyncOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Options")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Toggle("Compression", isOn: $options.compress)
                    Toggle("Archive mode", isOn: $options.archive)
                }
                GridRow {
                    Toggle("Delete extraneous files on target", isOn: $options.delete)
                    Toggle("Dry run (preview only)", isOn: $options.dryRun)
                }
                GridRow {
                    Toggle("Verbose logging", isOn: $options.verbose)
                    Toggle("Resume interrupted transfers", isOn: $options.resumePartial)
                }
            }
            .toggleStyle(.switch)

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

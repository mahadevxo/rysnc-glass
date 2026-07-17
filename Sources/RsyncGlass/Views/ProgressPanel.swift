import SwiftUI
import AppKit

struct ProgressPanel: View {
    var transferManager: TransferManager
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transfer")
                    .font(.headline)
                Spacer()
                Button {
                    transferManager.clearLog()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(transferManager.state.logLines.isEmpty)
                .help("Clear transfer output")
                statusBadge
            }

            if !transferManager.state.streams.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: transferManager.state.overallProgress)
                    Text("Overall — \(Int(transferManager.state.overallProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if transferManager.state.streams.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(transferManager.state.streams) { stream in
                            streamRow(stream)
                        }
                    }
                }
            }

            logView

            HStack {
                Spacer()
                if isRunning {
                    Button("Cancel", role: .destructive) {
                        transferManager.cancel()
                    }
                    .buttonStyle(.glass)
                } else {
                    Button(startButtonTitle, action: onStart)
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private func streamRow(_ stream: StreamState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Stream \(stream.id + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(stream.progressFraction * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: stream.progressFraction)
            if !stream.currentFile.isEmpty {
                Text(stream.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var logView: some View {
        let hasLog = !transferManager.state.logLines.isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                if hasLog {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(transferManager.state.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text("Transfer output will appear here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            }
            .frame(height: hasLog ? 180 : 100)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: hasLog)
            .onChange(of: transferManager.state.logLines.count) { _, _ in
                if let last = transferManager.state.logLines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var isRunning: Bool {
        switch transferManager.state.phase {
        case .running, .planning: return true
        default: return false
        }
    }

    private var startButtonTitle: String {
        switch transferManager.state.phase {
        case .cancelled:
            return "Resume Transfer"
        case .finished(let success) where !success:
            return "Resume Transfer"
        default:
            return "Start Transfer"
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.15), in: Capsule())
    }

    private var statusText: String {
        if !transferManager.state.statusMessage.isEmpty, isRunning || transferManager.state.phase == .idle {
            return transferManager.state.statusMessage
        }
        switch transferManager.state.phase {
        case .idle: return "Idle"
        case .planning: return "Planning…"
        case .running: return "Running…"
        case .finished(let success): return success ? "Finished" : "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch transferManager.state.phase {
        case .idle: return .gray
        case .planning, .running: return .blue
        case .finished(let success): return success ? .green : .red
        case .cancelled: return .orange
        }
    }
}

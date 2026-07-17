import SwiftUI

struct RemoteBrowserSheet: View {
    let endpoint: Endpoint
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = ""
    @State private var pathInput = ""
    @State private var entries: [RemoteEntry] = []
    @State private var selectedName: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browse \(endpoint.username)@\(endpoint.host)")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            pathBar
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button(selectButtonTitle, action: confirmSelection)
                    .buttonStyle(.borderedProminent)
                    .disabled(currentPath.isEmpty || isLoading)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .task {
            await load(path: endpoint.remotePath)
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(isLoading || currentPath.isEmpty || currentPath == "/")

            TextField("Path", text: $pathInput)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .onSubmit { Task { await load(path: pathInput) } }

            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Go") { Task { await load(path: pathInput) } }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Go to Home Folder") { Task { await load(path: "") } }
                    .buttonStyle(.borderless)
            }
        } else if entries.isEmpty && !isLoading {
            Text("This folder is empty.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: RemoteEntry) -> some View {
        Button {
            if entry.isDirectory {
                navigate(into: entry.name)
            } else {
                selectedName = entry.name
            }
        } label: {
            HStack {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                    .frame(width: 20)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                selectedName == entry.name ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectButtonTitle: String {
        selectedName != nil ? "Select File" : "Select This Folder"
    }

    private func confirmSelection() {
        if let selectedName {
            onSelect(PathUtilities.join(currentPath, selectedName))
        } else {
            onSelect(currentPath)
        }
        dismiss()
    }

    private func navigate(into name: String) {
        Task { await load(path: PathUtilities.join(currentPath, name)) }
    }

    private func goUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        Task { await load(path: parent.isEmpty ? "/" : parent) }
    }

    private func load(path: String) async {
        isLoading = true
        errorMessage = nil
        selectedName = nil
        do {
            let listing = try await RemoteBrowser.list(endpoint: endpoint, path: path)
            currentPath = listing.path
            pathInput = listing.path
            entries = listing.entries
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

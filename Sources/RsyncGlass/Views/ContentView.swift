import SwiftUI

struct ContentView: View {
    var transferManager: TransferManager

    @State private var source = Endpoint(label: "Source")
    @State private var target = Endpoint(label: "Target")
    @State private var options = RsyncOptions()
    @State private var serverStore = ServerStore()

    @State private var showSameLocationAlert = false
    @State private var showDeleteConfirmAlert = false

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 20) {
                VStack(spacing: 20) {
                    HStack(alignment: .endpointRow, spacing: 16) {
                        EndpointEditor(endpoint: source, serverStore: serverStore)

                        Button {
                            source.swapContents(with: target)
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.endpointRow) { d in d[VerticalAlignment.center] }
                        .help("Swap source and target")

                        EndpointEditor(endpoint: target, serverStore: serverStore)
                    }

                    OptionsPanel(options: options, isRemoteToRemote: source.kind == .remote && target.kind == .remote)

                    ProgressPanel(transferManager: transferManager) {
                        attemptStart()
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 940, minHeight: 800)
        .background(.background)
        .alert("Source and Target Are the Same", isPresented: $showSameLocationAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Transfer Anyway", role: .destructive) {
                if options.delete {
                    showDeleteConfirmAlert = true
                } else {
                    transferManager.start(source: source, target: target, options: options)
                }
            }
        } message: {
            Text("Source and target resolve to the same location. This transfer would have no effect, or could cause data loss if \"Delete extraneous files\" is on.")
        }
        .alert("Delete Extraneous Files Is On", isPresented: $showDeleteConfirmAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Start Transfer", role: .destructive) {
                transferManager.start(source: source, target: target, options: options)
            }
        } message: {
            Text("Files in the target that don't exist in the source will be permanently deleted. Double-check source and target before continuing.")
        }
    }

    private func attemptStart() {
        if source.isValid, target.isValid, source.resolvedLocationKey == target.resolvedLocationKey {
            showSameLocationAlert = true
            return
        }
        if options.delete {
            showDeleteConfirmAlert = true
            return
        }
        transferManager.start(source: source, target: target, options: options)
    }
}

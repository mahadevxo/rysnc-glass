import SwiftUI

struct ContentView: View {
    @State private var source = Endpoint(label: "Source")
    @State private var target = Endpoint(label: "Target")
    @State private var options = RsyncOptions()
    @State private var transferManager = TransferManager()
    @State private var serverStore = ServerStore()

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 20) {
                VStack(spacing: 20) {
                    HStack(alignment: .endpointRow, spacing: 16) {
                        EndpointEditor(endpoint: source, serverStore: serverStore)
                        Image(systemName: "arrow.right")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                            .alignmentGuide(.endpointRow) { d in d[VerticalAlignment.center] }
                        EndpointEditor(endpoint: target, serverStore: serverStore)
                    }

                    OptionsPanel(options: options)

                    ProgressPanel(transferManager: transferManager) {
                        transferManager.start(source: source, target: target, options: options)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 940, minHeight: 800)
        .background(.background)
    }
}

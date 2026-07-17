import SwiftUI

@main
struct RsyncGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var transferManager = TransferManager()

    var body: some Scene {
        WindowGroup("RsyncGlass") {
            ContentView(transferManager: transferManager)
                .onAppear { appDelegate.transferManager = transferManager }
        }
    }
}

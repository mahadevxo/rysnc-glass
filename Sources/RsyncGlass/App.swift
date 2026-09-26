import SwiftUI

@main
struct RsyncGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("RsyncGlass") {
            ContentView()
        }
    }
}

import AppKit

/// Prevents a silent Cmd+Q from leaving rsync/ssh processes orphaned mid-transfer
/// with no UI left to monitor or cancel them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = TransferManager.active
        guard !active.isEmpty else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = active.count == 1 ? "A Transfer Is Still Running" : "\(active.count) Transfers Are Still Running"
        alert.informativeText = "Quitting now will stop \(active.count == 1 ? "it" : "them"). Resume is on by default, so starting the same transfer again later will pick up where it left off."
        alert.alertStyle = .warning
        alert.addButton(withTitle: active.count == 1 ? "Quit and Stop Transfer" : "Quit and Stop Transfers")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            active.forEach { $0.cancel() }
            return .terminateNow
        }
        return .terminateCancel
    }
}

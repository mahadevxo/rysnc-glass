import AppKit

/// Prevents a silent Cmd+Q from leaving rsync/ssh processes orphaned mid-transfer
/// with no UI left to monitor or cancel them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var transferManager: TransferManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let transferManager, transferManager.isTransferActive else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "A Transfer Is Still Running"
        alert.informativeText = "Quitting now will stop it. Resume is on by default, so starting the same transfer again later will pick up where this one left off."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit and Stop Transfer")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            transferManager.cancel()
            return .terminateNow
        }
        return .terminateCancel
    }
}

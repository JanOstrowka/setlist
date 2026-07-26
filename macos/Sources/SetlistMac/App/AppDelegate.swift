import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `SetlistMacApp` at startup so termination can consult the
    /// workflow and stop only an owned backend.
    static weak var environment: SetlistAppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let environment = Self.environment else {
            return .terminateNow
        }

        let policy = TerminationPolicy(state: environment.workflow.state)
        switch policy.action {
        case .terminateNow:
            return .terminateNow
        case .confirmCancellation:
            guard confirmQuitDuringActiveWork() else {
                return .terminateCancel
            }
            Task {
                await environment.workflow.prepareForTermination()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.environment?.workflow.shutdown()
        BackendController.shared.stop()
    }

    private func confirmQuitDuringActiveWork() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A set is still in production"
        alert.informativeText =
            "Quitting now cancels the current download. "
            + "The set stays in Recent so you can retry it later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Set and Quit")
        alert.addButton(withTitle: "Keep Working")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

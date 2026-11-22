import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(settings: AppSettings, coordinator: AppCoordinator) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            settings: settings,
            onTestConnection: { [weak coordinator] in
                guard let coordinator else {
                    return ConnectionTestOutcome(success: false, message: "设置窗口不可用")
                }
                return await coordinator.testConnection()
            }
        )

        let hosting = NSHostingController(rootView: view)
        // Keep the window size under our control instead of the SwiftUI ideal size.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "iTrans 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 760))
        window.contentMinSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

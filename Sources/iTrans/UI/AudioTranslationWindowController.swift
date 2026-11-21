import AppKit
import SwiftUI

@MainActor
final class AudioTranslationWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var onClose: (() -> Void)?
    var onStop: (() -> Void)?
    var onStart: (() -> Void)?

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show(model: AudioTranslationViewModel) {
        if let window {
            window.orderFrontRegardless()
            return
        }

        let view = AudioTranslationView(
            model: model,
            onStop: { [weak self] in self?.onStop?() },
            onStart: { [weak self] in self?.onStart?() },
            onClose: { [weak self] in self?.close() },
            onOpenPrivacySettings: { PermissionManager.openPrivacySettings() }
        )

        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "实时语音翻译"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = hosting
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 520, height: 360)
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed

        position(window)
        self.window = window
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    private func position(_ window: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let x = visible.maxX - size.width - 24
        let y = visible.midY - size.height / 2
        window.setFrameOrigin(NSPoint(
            x: max(visible.minX + 12, x),
            y: max(visible.minY + 12, min(y, visible.maxY - size.height - 12))
        ))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window,
              let closed = notification.object as? NSWindow,
              closed === window else { return }
        self.window = nil
        onClose?()
    }
}

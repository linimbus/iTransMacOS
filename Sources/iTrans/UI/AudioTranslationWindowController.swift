import AppKit
import SwiftUI

final class AudioTranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
        contentMinSize = NSSize(width: 520, height: 360)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class AudioTranslationWindowController: NSObject, NSWindowDelegate {
    private static let frameDefaultsKey = "audioTranslationWindowFrame"

    private var window: AudioTranslationPanel?
    private var pendingFrameSave: DispatchWorkItem?

    var onClose: (() -> Void)?
    var onStop: (() -> Void)?
    var onStart: (() -> Void)?

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show(model: AudioTranslationViewModel, settings: AppSettings) {
        if let window {
            window.orderFrontRegardless()
            return
        }

        let view = AudioTranslationView(
            model: model,
            settings: settings,
            onStop: { [weak self] in self?.onStop?() },
            onStart: { [weak self] in self?.onStart?() },
            onClose: { [weak self] in self?.close() },
            onOpenPrivacySettings: { PermissionManager.openPrivacySettings() }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 560)

        let container = NSView(frame: hosting.frame)
        container.addSubview(hosting)

        let resizeOverlay = WindowResizeOverlay(frame: container.bounds)
        resizeOverlay.autoresizingMask = [.width, .height]
        container.addSubview(resizeOverlay)

        let panel = AudioTranslationPanel()
        panel.delegate = self
        panel.contentView = container

        restoreFrame(of: panel)
        self.window = panel
        panel.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    private func restoreFrame(of window: NSWindow) {
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= windowMinimum.width, frame.height >= windowMinimum.height {
                window.setFrame(constrainedFrame(frame), display: false)
                return
            }
        }
        window.setContentSize(NSSize(width: 760, height: 560))
        position(window)
    }

    private func saveFrame(of window: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
    }

    private func constrainedFrame(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }

        let size = NSSize(
            width: max(windowMinimum.width, frame.width),
            height: max(windowMinimum.height, frame.height)
        )

        if let screen = screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            return NSRect(
                x: min(max(frame.minX, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8)),
                y: min(max(frame.minY, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8)),
                width: min(size.width, visible.width - 16),
                height: min(size.height, visible.height - 16)
            )
        }
        return NSRect(origin: frame.origin, size: size)
    }

    private var windowMinimum: NSSize {
        NSSize(width: 520, height: 360)
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

    func windowDidMove(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        saveFrame(of: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        pendingFrameSave?.cancel()
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.saveFrame(of: window)
        }
        pendingFrameSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        pendingFrameSave?.cancel()
        pendingFrameSave = nil
        saveFrame(of: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window,
              let closed = notification.object as? NSWindow,
              closed === window else { return }
        saveFrame(of: window)
        self.window = nil
        onClose?()
    }
}

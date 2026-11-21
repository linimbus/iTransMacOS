import AppKit
import SwiftUI

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((NSSize) -> Void)?
    private var lastReportedSize: NSSize = .zero

    override func layout() {
        super.layout()
        let size = fittingSize
        guard size.height > 1 else { return }
        if abs(size.height - lastReportedSize.height) > 0.5
            || abs(size.width - lastReportedSize.width) > 0.5 {
            lastReportedSize = size
            onSizeChange?(size)
        }
    }
}

@MainActor
final class PopupController: NSObject, NSWindowDelegate {
    private let popupWidth: CGFloat = 420

    private var panel: PopupPanel?
    private var model: PopupModel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var ignoreResignUntil: Date = .distantPast
    private var isPinned = false

    var requestTranslate: ((PopupModel) -> Void)?
    var requestSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    var currentModel: PopupModel? { model }
    var isVisible: Bool { panel?.isVisible == true }

    /// While pinned, the panel ignores automatic outside-click / focus-loss dismissal.
    /// Used while the macOS translation preparation window is shown.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }

    func focus() {
        guard let panel, panel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func present(model: PopupModel, at point: NSPoint) {
        close()

        AppLog.popup.info("Presenting popup at \(String(describing: point), privacy: .public)")

        self.model = model
        model.phase = .prompt

        let root = PopupView(
            model: model,
            onTranslate: { [weak self] in self?.requestTranslate?(model) },
            onRetry: { [weak self] in self?.requestTranslate?(model) },
            onClose: { [weak self] in self?.close() },
            onCopy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                model.flashCopied()
            },
            onOpenSettings: { [weak self] in
                self?.requestSettings?()
            }
        )

        let hosting = AutoSizingHostingView(rootView: root)
        hosting.onSizeChange = { [weak self] size in
            self?.applyContentSize(height: size.height)
        }

        let panel = PopupPanel()
        panel.delegate = self
        panel.contentView = hosting
        panel.setContentSize(NSSize(width: popupWidth, height: 120))

        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let height = clampHeight(fitting.height > 1 ? fitting.height : 120)
        panel.setContentSize(NSSize(width: popupWidth, height: height))
        position(panel, near: point, height: height, animate: false)

        self.panel = panel
        ignoreResignUntil = Date().addingTimeInterval(0.35)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            panel.animator().alphaValue = 1
        }

        installMonitors()
    }

    func close() {
        let wasVisible = panel?.isVisible == true
        isPinned = false
        removeMonitors()
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        model = nil
        if wasVisible {
            onDismiss?()
        }
    }

    // MARK: - Sizing / positioning

    private func clampHeight(_ value: CGFloat) -> CGFloat {
        min(max(value.rounded(.up), 70), 680)
    }

    private func applyContentSize(height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        let newHeight = clampHeight(height)
        guard abs(panel.frame.height - newHeight) > 0.5 else { return }

        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: popupWidth, height: newHeight)
        frame.origin.y = top - newHeight
        frame = clampToScreen(frame)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func position(_ panel: NSPanel, near point: NSPoint, height: CGFloat, animate: Bool) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = popupWidth
        let gap: CGFloat = 14

        var x = point.x + gap
        var y = point.y - height - gap

        if x + width > visible.maxX {
            x = point.x - width - gap
        }
        if y < visible.minY {
            y = point.y + gap
        }
        if y + height > visible.maxY {
            y = visible.maxY - height - 8
        }

        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)

        let frame = NSRect(x: x, y: y, width: width, height: height)
        panel.setFrame(frame, display: true, animate: animate)
    }

    private func clampToScreen(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main else {
            return frame
        }
        let visible = screen.visibleFrame
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX + 8), visible.maxX - result.width - 8)
        result.origin.y = min(max(result.minY, visible.minY + 8), visible.maxY - result.height - 8)
        return result
    }

    // MARK: - Monitors

    private func installMonitors() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let panel = self.panel, event.window !== panel, !self.isPinned {
                self.close()
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isPinned else { return }
                self.close()
            }
        }
    }

    private func removeMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard Date() >= ignoreResignUntil, !isPinned else { return }
        close()
    }
}

import AppKit
import SwiftUI

final class ManualTranslationWindow: NSWindow {
    var onCloseRequest: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        contentMinSize = NSSize(width: 480, height: 340)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCloseRequest?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class ManualTranslationController: NSObject, NSWindowDelegate {
    private static let frameDefaultsKey = "manualTranslationWindowFrame"
    private static let defaultSize = NSSize(width: 600, height: 460)
    private static let minimumSize = NSSize(width: 480, height: 340)

    private let settings: AppSettings
    private let translator: TranslationService
    private let systemTranslator: SystemTranslationService

    private let model = ManualTranslationViewModel()
    private var window: ManualTranslationWindow?
    private var pendingFrameSave: DispatchWorkItem?
    private var keyMonitor: Any?

    init(
        settings: AppSettings,
        translator: TranslationService,
        systemTranslator: SystemTranslationService
    ) {
        self.settings = settings
        self.translator = translator
        self.systemTranslator = systemTranslator
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func toggle() {
        if isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.focusRequest += 1

        // SwiftUI's `@FocusState` assignment is dropped when it happens before the
        // borderless window becomes key, so re-request focus once it is key.
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.window?.isKeyWindow == true else { return }
                self.model.focusRequest += 1
            }
        }
    }

    func close() {
        guard let window else { return }
        saveFrame(of: window)
        window.orderOut(nil)
    }

    func translate() {
        guard model.canTranslate else { return }
        let text = model.trimmedInput
        guard !text.isEmpty else { return }

        model.beginLoading()

        let usesSystemEngine = settings.isSystemEngine
        let sourceLanguageID = settings.sourceLanguageID
        let targetLanguageID = settings.targetLanguageID
        let anchor = window.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) }
            ?? NSEvent.mouseLocation

        // The system engine may present its language-pack window at the normal
        // window level, so step down from `.floating` while it is preparing.
        if usesSystemEngine {
            window?.level = .normal
        }

        Task { @MainActor in
            defer {
                if usesSystemEngine {
                    self.window?.level = .floating
                }
            }

            do {
                let translatedText: String
                let endpoint: String

                if usesSystemEngine {
                    translatedText = try await systemTranslator.translate(
                        text: text,
                        sourceLanguageID: sourceLanguageID,
                        targetLanguageID: targetLanguageID,
                        anchor: anchor
                    )
                    endpoint = "macOS 系统翻译"
                } else {
                    let result = try await translator.translate(text: text, settings: settings)
                    translatedText = result.text
                    endpoint = result.endpointDescription
                }

                model.finish(text: translatedText, endpoint: endpoint)
                AppLog.translate.info("Manual translation via \(endpoint, privacy: .public)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                model.fail(message)
                AppLog.translate.error("Manual translation failed: \(message, privacy: .public)")
            }
        }
    }

    /// Development helper: `iTrans --demo-manual` shows a populated window.
    func showDemoWindow() {
        model.inputText = "The quick brown fox jumps over the lazy dog. This is a demo of the manual translation window."
        model.finish(
            text: "敏捷的棕色狐狸跳过了懒狗。这是手动翻译窗口的演示。",
            endpoint: "macOS 系统翻译"
        )
        show()
    }

    // MARK: - Window

    private func ensureWindow() -> ManualTranslationWindow {
        if let window { return window }

        let view = ManualTranslationView(
            model: model,
            settings: settings,
            onTranslate: { [weak self] in self?.translate() },
            onClose: { [weak self] in self?.close() },
            onClear: { [weak self] in self?.model.clear() }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: Self.defaultSize)

        let container = NSView(frame: hosting.frame)
        container.addSubview(hosting)

        let resizeOverlay = WindowResizeOverlay(frame: container.bounds)
        resizeOverlay.autoresizingMask = [.width, .height]
        container.addSubview(resizeOverlay)

        let window = ManualTranslationWindow()
        window.delegate = self
        window.onCloseRequest = { [weak self] in self?.close() }
        window.contentView = container

        // The focused text view consumes Escape, so close the window from a local
        // monitor before the event is dispatched.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 53,
                  let window = self.window,
                  window.isKeyWindow else {
                return event
            }
            self.close()
            return nil
        }

        restoreFrame(of: window)
        self.window = window
        return window
    }

    private func restoreFrame(of window: NSWindow) {
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= Self.minimumSize.width, frame.height >= Self.minimumSize.height {
                window.setFrame(constrainedFrame(frame), display: false)
                return
            }
        }
        window.setContentSize(Self.defaultSize)
        position(window)
    }

    private func saveFrame(of window: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
    }

    private func constrainedFrame(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }

        let size = NSSize(
            width: max(Self.minimumSize.width, frame.width),
            height: max(Self.minimumSize.height, frame.height)
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

    private func position(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size

        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2
        window.setFrameOrigin(NSPoint(
            x: max(visible.minX + 12, min(x, visible.maxX - size.width - 12)),
            y: max(visible.minY + 12, min(y, visible.maxY - size.height - 12))
        ))
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    // MARK: - NSWindowDelegate

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
}

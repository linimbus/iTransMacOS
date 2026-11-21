import AppKit
import Combine
import Translation

@MainActor
final class AppCoordinator: NSObject {
    let settings = AppSettings()

    private let hotKeyManager = HotKeyManager()
    private let translator = TranslationService()
    private let systemTranslator = SystemTranslationService()
    private lazy var audioTranslationController = AudioTranslationController(
        settings: settings,
        translator: translator,
        systemTranslator: systemTranslator
    )
    private lazy var popup = PopupController(settings: settings)
    private let screenCapture = ScreenCaptureService()
    private let ocrService = OCRService()
    private let selectedTextService = SelectedTextService()

    private var statusBar: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var selectionController: RegionSelectionController?
    private var cancellables = Set<AnyCancellable>()
    private var isBusy = false
    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true

        popup.requestTranslate = { [weak self] model in
            self?.translate(popupModel: model)
        }
        popup.requestSettings = { [weak self] in
            self?.openSettings()
        }
        popup.onDismiss = { [weak self] in
            self?.systemTranslator.cancelCurrent()
        }

        statusBar = StatusBarController(coordinator: self, settings: settings)
        settingsWindowController = SettingsWindowController()

        registerHotKeys()

        settings.$ocrShortcut
            .dropFirst()
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)

        settings.$selectionShortcut
            .dropFirst()
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)

        settings.$audioShortcut
            .dropFirst()
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)

        AppLog.app.info("iTrans started")

        handleDemoArgumentsIfNeeded()
        handleDemoSelectIfNeeded()
        handleDemoSelectionIfNeeded()
        handleDemoAudioIfNeeded()
    }

    /// Development helper: `iTrans --demo-selection` shows a selection translation panel.
    private func handleDemoSelectionIfNeeded() {
        guard CommandLine.arguments.contains("--demo-selection") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.presentPopup(
                text: "Select text anywhere on your screen, and the translation appears right next to your cursor. No extra windows, no copy-paste.",
                origin: .selection,
                forceTranslate: true
            )
        }
    }

    /// Development helpers:
    /// `iTrans --demo-audio` starts a real audio session.
    /// `iTrans --demo-audio-window` shows a populated window for documentation.
    private func handleDemoAudioIfNeeded() {
        if CommandLine.arguments.contains("--demo-audio-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.audioTranslationController.showDemoWindow()
            }
            return
        }

        guard CommandLine.arguments.contains("--demo-audio") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.toggleAudioTranslation()
        }
    }

    /// Development helper: `iTrans --demo` shows a sample popup without OCR.
    private func handleDemoArgumentsIfNeeded() {
        guard CommandLine.arguments.contains("--demo") else { return }

        if let server = ProcessInfo.processInfo.environment["ITRANS_SERVER"], !server.isEmpty {
            settings.transientServerURL = URL(string: server)
        }

        let autoTranslate = ProcessInfo.processInfo.environment["ITRANS_DEMO_AUTO"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.presentPopup(
                text: "The quick brown fox jumps over the lazy dog. This is a demo text for the iTrans floating panel.",
                origin: .screenshot,
                forceTranslate: autoTranslate
            )
        }
    }

    private func handleDemoSelectIfNeeded() {
        guard CommandLine.arguments.contains("--demo-select") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let controller = RegionSelectionController()
                self.selectionController = controller
                let selection = await controller.select()
                self.selectionController = nil
                if let selection {
                    self.presentPopup(
                        text: "Selected region: \(Int(selection.width)) × \(Int(selection.height))",
                        origin: .screenshot
                    )
                }
            }
        }
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        hotKeyManager.unregisterAll()
        hotKeyManager.register(settings.ocrShortcut) { [weak self] in
            self?.startScreenshotOCR()
        }
        hotKeyManager.register(settings.selectionShortcut) { [weak self] in
            self?.startSelectionTranslation()
        }
        hotKeyManager.register(settings.audioShortcut) { [weak self] in
            self?.toggleAudioTranslation()
        }
    }

    // MARK: - Screenshot OCR

    func startScreenshotOCR() {
        guard !isBusy else { return }
        isBusy = true
        systemTranslator.cancelCurrent()
        popup.close()

        Task { @MainActor in
            defer { isBusy = false }

            if !PermissionManager.screenRecordingGranted {
                if !PermissionManager.requestScreenRecording() {
                    showPermissionAlert(for: .screenRecording)
                    return
                }
            }

            do {
                let screens = try await screenCapture.captureAllScreens()
                guard !screens.isEmpty else {
                    showError(title: "截图失败", message: "没有捕获到任何屏幕。")
                    return
                }

                let controller = RegionSelectionController()
                selectionController = controller
                let selection = await controller.select()
                selectionController = nil

                guard let selection else { return }

                guard let cropped = OCRService.crop(screens, globalRect: selection) else {
                    showError(title: "截图失败", message: "无法裁剪所选区域，请重试。")
                    return
                }

                let text = try await ocrService.recognize(
                    image: cropped,
                    languages: settings.ocrLanguages
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmed.isEmpty else {
                    showNotice(
                        title: "未识别到文字",
                        message: "请重新框选包含清晰文字的区域。"
                    )
                    return
                }

                AppLog.capture.info("Recognized \(trimmed.count, privacy: .public) characters")
                presentPopup(text: trimmed, origin: .screenshot, forceTranslate: true)
            } catch {
                AppLog.capture.error("Capture/OCR failed: \(error.localizedDescription, privacy: .public)")
                if !PermissionManager.screenRecordingGranted {
                    showPermissionAlert(for: .screenRecording)
                } else {
                    showError(title: "截图识别失败", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Selection translation

    func startSelectionTranslation() {
        guard !isBusy else { return }
        isBusy = true
        systemTranslator.cancelCurrent()
        popup.close()

        Task { @MainActor in
            defer { isBusy = false }

            if !PermissionManager.accessibilityGranted {
                PermissionManager.requestAccessibility()
                showPermissionAlert(for: .accessibility)
                return
            }

            let selected = await selectedTextService.readSelectedText()
            guard let text = selected?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                showNotice(
                    title: "没有读取到选中的文字",
                    message: "请先在任意应用中选中文本，再按 \(settings.selectionShortcut.displayString)。"
                )
                return
            }

            presentPopup(text: text, origin: .selection)
        }
    }

    // MARK: - Audio translation

    func toggleAudioTranslation() {
        guard !isBusy else { return }
        popup.close()
        audioTranslationController.toggle()
    }

    // MARK: - Popup

    private func presentPopup(text: String, origin: PopupModel.Origin, forceTranslate: Bool = false) {
        let point = NSEvent.mouseLocation
        let model = PopupModel(
            originalText: text,
            origin: origin
        )
        popup.present(model: model, at: point)

        if forceTranslate || settings.autoTranslate {
            translate(popupModel: model)
        }
    }

    private func translate(popupModel model: PopupModel) {
        guard model.phase != .loading else { return }
        model.phase = .loading
        model.errorMessage = nil

        let text = model.originalText
        let usesSystemEngine = settings.isSystemEngine
        if usesSystemEngine {
            popup.setPinned(true)
        }

        Task { @MainActor in
            do {
                let translatedText: String
                let endpoint: String

                if usesSystemEngine {
                    translatedText = try await systemTranslator.translate(
                        text: text,
                        sourceLanguageID: settings.sourceLanguageID,
                        targetLanguageID: settings.targetLanguageID,
                        anchor: NSEvent.mouseLocation
                    )
                    endpoint = "macOS 系统翻译"
                } else {
                    let result = try await translator.translate(text: text, settings: settings)
                    translatedText = result.text
                    endpoint = result.endpointDescription
                }

                popup.setPinned(false)
                guard popup.currentModel === model else { return }
                model.translatedText = translatedText
                model.endpointDescription = endpoint
                model.phase = .success
                if usesSystemEngine { popup.focus() }
                AppLog.translate.info("Translated via \(endpoint, privacy: .public)")
            } catch {
                popup.setPinned(false)
                guard popup.currentModel === model else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                model.errorMessage = message
                model.phase = .failure
                if usesSystemEngine { popup.focus() }
                AppLog.translate.error("Translation failed: \(message, privacy: .public)")
            }
        }
    }

    // MARK: - Settings / testing

    func openSettings() {
        settingsWindowController?.show(settings: settings, coordinator: self)
    }

    func testConnection() async -> ConnectionTestOutcome {
        if settings.isSystemEngine {
            return await testSystemTranslation()
        }

        guard settings.serverBaseURL != nil else {
            return ConnectionTestOutcome(success: false, message: "服务地址格式无效")
        }

        do {
            let result = try await translator.translate(text: "Hello", settings: settings)
            let preview = result.text
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(24)
            return ConnectionTestOutcome(
                success: true,
                message: "连接成功（\(result.endpointDescription)）：\(preview)"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ConnectionTestOutcome(success: false, message: message)
        }
    }

    private func testSystemTranslation() async -> ConnectionTestOutcome {
        guard #available(macOS 15.0, *) else {
            return ConnectionTestOutcome(success: false, message: "系统翻译需要 macOS 15 或更高版本")
        }

        let sourceIdentifier = settings.sourceLanguageID == "auto"
            ? "en-US"
            : settings.systemLanguageIdentifier(for: settings.sourceLanguageID)
        let source = Locale.Language(identifier: sourceIdentifier)
        let target = Locale.Language(
            identifier: settings.systemLanguageIdentifier(for: settings.targetLanguageID)
        )
        let status = await LanguageAvailability().status(from: source, to: target)

        switch status {
        case .installed:
            return ConnectionTestOutcome(
                success: true,
                message: "系统翻译已就绪，可直接翻译到\(settings.targetLanguageName)"
            )
        case .supported:
            return ConnectionTestOutcome(
                success: true,
                message: "系统支持翻译到\(settings.targetLanguageName)，首次翻译时会提示下载语言包"
            )
        case .unsupported:
            return ConnectionTestOutcome(
                success: false,
                message: "macOS 系统翻译暂不支持\(settings.targetLanguageName)，可切换为 LibreTranslate"
            )
        @unknown default:
            return ConnectionTestOutcome(success: false, message: "无法确定 macOS 系统翻译状态")
        }
    }

    // MARK: - Alerts

    private enum PermissionKind {
        case accessibility
        case screenRecording
    }

    private func showPermissionAlert(for kind: PermissionKind) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning

        switch kind {
        case .accessibility:
            alert.messageText = "需要“辅助功能”权限"
            alert.informativeText = "划词翻译需要读取当前选中的文本。请前往 系统设置 → 隐私与安全性 → 辅助功能，勾选 iTrans（若列表中没有，可在“+”中手动添加应用）。"
        case .screenRecording:
            alert.messageText = "需要“屏幕录制”权限"
            alert.informativeText = "截图识别需要捕获屏幕内容。请前往 系统设置 → 隐私与安全性 → 屏幕录制，勾选 iTrans，然后重新启动应用。"
        }

        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            switch kind {
            case .accessibility:
                PermissionManager.openAccessibilitySettings()
            case .screenRecording:
                PermissionManager.openScreenRecordingSettings()
            }
        }
    }

    private func showError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showNotice(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

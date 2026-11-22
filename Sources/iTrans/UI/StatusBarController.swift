import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var coordinator: AppCoordinator?
    private let settings: AppSettings

    private var ocrItem: NSMenuItem?
    private var selectionItem: NSMenuItem?
    private var audioItem: NSMenuItem?
    private var manualItem: NSMenuItem?
    private var autoTranslateItem: NSMenuItem?
    private var engineItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    init(coordinator: AppCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "iTrans")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "iTrans · OCR / 划词 / 语音 / 手动翻译"
        }

        buildMenu()

        settings.$ocrShortcut
            .merge(with: settings.$selectionShortcut)
            .merge(with: settings.$audioShortcut)
            .merge(with: settings.$manualShortcut)
            .sink { [weak self] _ in self?.refreshMenuItems() }
            .store(in: &cancellables)

        settings.$autoTranslate
            .sink { [weak self] _ in self?.refreshMenuItems() }
            .store(in: &cancellables)

        settings.$translationEngineID
            .sink { [weak self] _ in self?.refreshMenuItems() }
            .store(in: &cancellables)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let ocr = NSMenuItem(title: "截图识别 OCR", action: #selector(triggerOCR), keyEquivalent: "")
        ocr.target = self
        menu.addItem(ocr)
        ocrItem = ocr

        let selection = NSMenuItem(title: "划词翻译", action: #selector(triggerSelection), keyEquivalent: "")
        selection.target = self
        menu.addItem(selection)
        selectionItem = selection

        let manual = NSMenuItem(title: "手动翻译", action: #selector(toggleManualTranslation), keyEquivalent: "")
        manual.target = self
        menu.addItem(manual)
        manualItem = manual

        let audio = NSMenuItem(title: "实时语音翻译", action: #selector(toggleAudioTranslation), keyEquivalent: "")
        audio.target = self
        menu.addItem(audio)
        audioItem = audio

        menu.addItem(.separator())

        let auto = NSMenuItem(title: "自动翻译", action: #selector(toggleAutoTranslate), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        autoTranslateItem = auto

        let engine = NSMenuItem(title: "翻译引擎", action: nil, keyEquivalent: "")
        engine.isEnabled = false
        menu.addItem(engine)
        engineItem = engine

        menu.addItem(.separator())

        let permission = NSMenuItem(title: "权限状态", action: nil, keyEquivalent: "")
        permission.isEnabled = false
        menu.addItem(permission)
        permissionItem = permission

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 iTrans", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        ocrItem?.title = "截图识别 OCR（\(settings.ocrShortcut.displayString)）"
        selectionItem?.title = "划词翻译（\(settings.selectionShortcut.displayString)）"
        audioItem?.title = "实时语音翻译（\(settings.audioShortcut.displayString)）"
        manualItem?.title = "手动翻译（\(settings.manualShortcut.displayString)）"
        autoTranslateItem?.state = settings.autoTranslate ? .on : .off
        engineItem?.title = "翻译引擎：\(settings.translationEngine.displayName)"

        let accessibility = PermissionManager.accessibilityGranted ? "辅助功能 ✓" : "辅助功能 ✗"
        let screen = PermissionManager.screenRecordingGranted ? "屏幕录制 ✓" : "屏幕录制 ✗"
        permissionItem?.title = "权限：\(accessibility) · \(screen)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems()
    }

    @objc private func triggerOCR() {
        coordinator?.startScreenshotOCR()
    }

    @objc private func triggerSelection() {
        coordinator?.startSelectionTranslation()
    }

    @objc private func toggleAudioTranslation() {
        coordinator?.toggleAudioTranslation()
    }

    @objc private func toggleManualTranslation() {
        coordinator?.toggleManualTranslation()
    }

    @objc private func toggleAutoTranslate() {
        settings.autoTranslate.toggle()
    }

    @objc private func openSettings() {
        coordinator?.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

import AppKit
import AVFoundation
import SwiftUI
import Combine

struct ConnectionTestOutcome {
    let success: Bool
    let message: String
}

private struct RunningAppOption: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onTestConnection: () async -> ConnectionTestOutcome

    /// Marketing version from Info.plist, shown in the About section.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    @State private var testState: TestState = .idle
    @State private var showAdvanced = false
    @State private var accessibilityGranted = PermissionManager.accessibilityGranted
    @State private var screenRecordingGranted = PermissionManager.screenRecordingGranted
    @State private var microphoneGranted = PermissionManager.microphoneGranted
    @State private var runningApps: [RunningAppOption] = []

    private enum TestState {
        case idle
        case testing
        case finished(ConnectionTestOutcome)
    }

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            engineSection

            if settings.translationEngine == .libretranslate {
                serverSection
                advancedSection
            } else {
                systemSection
            }

            audioSection
            triggerSection
            permissionSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 760)
        .onReceive(permissionTimer) { _ in
            accessibilityGranted = PermissionManager.accessibilityGranted
            screenRecordingGranted = PermissionManager.screenRecordingGranted
            microphoneGranted = PermissionManager.microphoneGranted
        }
        .onAppear {
            loadRunningApps()
        }
        .onChange(of: settings.translationEngineID) { _, _ in
            testState = .idle
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            Picker("翻译引擎", selection: $settings.translationEngineID) {
                ForEach(TranslationEngineKind.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }

            Picker("目标语言", selection: $settings.targetLanguageID) {
                ForEach(Languages.targets) { language in
                    Text(language.name).tag(language.id)
                }
            }

            Picker("源语言 / OCR / 音频语言", selection: $settings.sourceLanguageID) {
                ForEach(Languages.sources) { language in
                    Text(language.name).tag(language.id)
                }
            }

            Toggle("划词后自动翻译（不显示翻译按钮）", isOn: $settings.autoTranslate)
        } header: {
            Text("翻译引擎")
        } footer: {
            Text(settings.translationEngine.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - System engine

    private var systemSection: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    HStack(spacing: 5) {
                        if case .testing = testState {
                            ProgressView().controlSize(.small)
                        }
                        Text("检查系统翻译")
                    }
                }
                .disabled(isTesting)

                testResultView

                Spacer()
            }
        } header: {
            Text("macOS 系统翻译")
        } footer: {
            Text("使用端侧翻译。首次翻译某个语言组合时，系统会提示下载语言包；如果下载失败或系统不支持目标语言，可在上方切换为 LibreTranslate。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - LibreTranslate

    private var serverSection: some View {
        Section {
            TextField("服务地址", text: $settings.serverURL, prompt: Text("http://192.168.3.3:5000"))
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    HStack(spacing: 5) {
                        if case .testing = testState {
                            ProgressView().controlSize(.small)
                        }
                        Text("测试连接")
                    }
                }
                .disabled(isTesting)

                testResultView

                Spacer()
            }
        } header: {
            Text("LibreTranslate 服务")
        } footer: {
            Text("接口会自动读取 openapi.json 或 Swagger spec（如 /spec）发现；识别不到时可在“高级设置”中手动指定。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            Text("正在测试…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .finished(let outcome):
            Label(outcome.message, systemImage: outcome.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(outcome.success ? Color.green : Color.orange)
                .lineLimit(2)
        }
    }

    private var isTesting: Bool {
        if case .testing = testState { return true }
        return false
    }

    private func runConnectionTest() async {
        testState = .testing
        let outcome = await onTestConnection()
        testState = .finished(outcome)
    }

    // MARK: - Live audio translation

    private var audioSection: some View {
        Section {
            Picker("语音识别引擎", selection: $settings.speechEngineID) {
                ForEach(SpeechEngineKind.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }

            Picker("音频来源", selection: $settings.audioSourceModeID) {
                ForEach(AudioSourceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            if settings.audioSourceMode == .application {
                HStack {
                    Picker("来源应用", selection: audioAppBinding) {
                        ForEach(runningApps) { app in
                            Text(app.name).tag(app.id)
                        }
                        if !settings.audioAppBundleID.isEmpty,
                           !runningApps.contains(where: { $0.id == settings.audioAppBundleID }) {
                            Text("\(settings.audioAppName)（未运行）")
                                .tag(settings.audioAppBundleID)
                        }
                    }

                    Button {
                        loadRunningApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("刷新正在运行的应用列表")
                }

                if runningApps.isEmpty {
                    Text("未检测到正在运行的普通应用。请先打开会议软件或浏览器，再点击刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.audioSourceMode == .microphone {
                LabeledContent("输入设备") {
                    Text(AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认输入设备")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("快捷键")
                Spacer()
                HotKeyRecorderView(shortcut: $settings.audioShortcut)
                    .frame(width: 150, height: 24)
                Button("恢复默认") {
                    settings.audioShortcut = .audioDefault
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } header: {
            Text("实时语音翻译")
        } footer: {
            Text("\(settings.speechEngine.summary) 音频语言与 OCR 源语言共用同一设置。系统声音/指定应用需要屏幕录制权限；麦克风需要麦克风权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioAppBinding: Binding<String> {
        Binding(
            get: { settings.audioAppBundleID },
            set: { newValue in
                settings.audioAppBundleID = newValue
                if let app = runningApps.first(where: { $0.id == newValue }) {
                    settings.audioAppName = app.name
                }
            }
        )
    }

    private func loadRunningApps() {
        let ownBundleID = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppOption? in
                guard let identifier = app.bundleIdentifier,
                      identifier != ownBundleID else { return nil }
                return RunningAppOption(
                    id: identifier,
                    name: app.localizedName ?? identifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        runningApps = apps

        if let selected = apps.first(where: { $0.id == settings.audioAppBundleID }) {
            settings.audioAppName = selected.name
        } else if settings.audioAppBundleID.isEmpty,
                  settings.audioSourceMode == .application,
                  let first = apps.first {
            settings.audioAppBundleID = first.id
            settings.audioAppName = first.name
        }
    }

    // MARK: - Triggers

    private var triggerSection: some View {
        Section {
            HStack {
                Text("截图识别")
                Spacer()
                HotKeyRecorderView(shortcut: $settings.ocrShortcut)
                    .frame(width: 150, height: 24)
                Button("恢复默认") {
                    settings.ocrShortcut = .ocrDefault
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            HStack {
                Text("划词翻译")
                Spacer()
                HotKeyRecorderView(shortcut: $settings.selectionShortcut)
                    .frame(width: 150, height: 24)
                Button("恢复默认") {
                    settings.selectionShortcut = .selectionDefault
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            HStack {
                Text("手动翻译")
                Spacer()
                HotKeyRecorderView(shortcut: $settings.manualShortcut)
                    .frame(width: 150, height: 24)
                Button("恢复默认") {
                    settings.manualShortcut = .manualDefault
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if let conflict = shortcutConflictMessage {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("快捷键")
        } footer: {
            Text("点击快捷键框后按下新的组合键；需要至少包含一个修饰键（⌘⌥⌃⇧）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutConflictMessage: String? {
        let entries: [(String, HotKeyShortcut)] = [
            ("截图识别", settings.ocrShortcut),
            ("划词翻译", settings.selectionShortcut),
            ("手动翻译", settings.manualShortcut),
            ("实时语音翻译", settings.audioShortcut)
        ].filter { $0.1.isValid }

        for i in entries.indices {
            for j in entries.indices where j > i {
                if entries[i].1 == entries[j].1 {
                    return "「\(entries[i].0)」与「\(entries[j].0)」快捷键相同，其中一个将无法生效"
                }
            }
        }
        return nil
    }

    // MARK: - Permissions

    private var permissionSection: some View {
        Section {
            permissionRow(
                title: "辅助功能权限",
                detail: "用于读取当前选中的文字（划词翻译）",
                granted: accessibilityGranted,
                action: {
                    PermissionManager.requestAccessibility()
                    PermissionManager.openAccessibilitySettings()
                }
            )

            permissionRow(
                title: "屏幕录制权限",
                detail: "用于截取屏幕区域进行 OCR、捕获系统音频",
                granted: screenRecordingGranted,
                action: {
                    PermissionManager.requestScreenRecording()
                    PermissionManager.openScreenRecordingSettings()
                }
            )

            permissionRow(
                title: "麦克风权限",
                detail: "用于麦克风实时语音翻译",
                granted: microphoneGranted,
                action: {
                    if PermissionManager.microphoneStatus == .notDetermined {
                        PermissionManager.requestMicrophone()
                    } else {
                        PermissionManager.openMicrophoneSettings()
                    }
                }
            )

        } header: {
            Text("系统权限")
        } footer: {
            Text("首次使用后需要在“系统设置 → 隐私与安全性”中勾选 iTrans；重新编译安装后可能需要重新授权。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "已授权" : "未授权")
                .font(.caption)
                .foregroundStyle(granted ? .secondary : Color.orange)
            if !granted {
                Button("去授权", action: action)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级设置：手动指定 API", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("留空接口路径时自动发现。只有在自动发现失败或字段不匹配时才需要填写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("接口路径") {
                        TextField("", text: $settings.apiPath, prompt: Text("/translate"))
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("请求方法") {
                        Picker("", selection: $settings.apiMethod) {
                            Text("POST").tag("POST")
                            Text("GET").tag("GET")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }

                    LabeledContent("文本字段") {
                        TextField("", text: $settings.apiTextField, prompt: Text("text"))
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("目标语言字段") {
                        TextField("", text: $settings.apiTargetField, prompt: Text("target_lang"))
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("源语言字段") {
                        TextField("", text: $settings.apiSourceField, prompt: Text("source_lang，可留空"))
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("译文响应路径") {
                        TextField("", text: $settings.apiResponsePath, prompt: Text("data.translation，可留空"))
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("目标语言发送值") {
                        TextField("", text: $settings.targetValueOverride, prompt: Text("留空则使用 \(settings.effectiveTargetValue)"))
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("清空手动配置") {
                            settings.apiPath = ""
                            settings.apiTextField = ""
                            settings.apiTargetField = ""
                            settings.apiSourceField = ""
                            settings.apiResponsePath = ""
                            settings.targetValueOverride = ""
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("iTrans \(Self.appVersion)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复全部默认设置") {
                    settings.resetToDefaults()
                }
                .controlSize(.small)
            }
        }
    }
}

import AppKit
import Combine

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
    let visionCode: String?
}

enum Languages {
    static let targets: [LanguageOption] = [
        LanguageOption(id: "zh", name: "简体中文", visionCode: "zh-Hans"),
        LanguageOption(id: "zh-TW", name: "繁體中文", visionCode: "zh-Hant"),
        LanguageOption(id: "en", name: "English", visionCode: "en-US"),
        LanguageOption(id: "ja", name: "日本語", visionCode: "ja-JP"),
        LanguageOption(id: "ko", name: "한국어", visionCode: "ko-KR"),
        LanguageOption(id: "fr", name: "Français", visionCode: "fr-FR"),
        LanguageOption(id: "de", name: "Deutsch", visionCode: "de-DE"),
        LanguageOption(id: "es", name: "Español", visionCode: "es-ES"),
        LanguageOption(id: "ru", name: "Русский", visionCode: "ru-RU"),
        LanguageOption(id: "pt", name: "Português", visionCode: "pt-BR"),
        LanguageOption(id: "it", name: "Italiano", visionCode: "it-IT")
    ]

    static let sources: [LanguageOption] = [
        LanguageOption(id: "auto", name: "自动检测", visionCode: nil)
    ] + targets

    static func name(for id: String) -> String {
        targets.first(where: { $0.id == id })?.name ?? id
    }

    static func visionCode(for id: String) -> String? {
        targets.first(where: { $0.id == id })?.visionCode
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let translationEngine = "translationEngine"
        static let serverURL = "serverURL"
        static let targetLanguageID = "targetLanguageID"
        static let sourceLanguageID = "sourceLanguageID"
        static let autoTranslate = "autoTranslate"
        static let ocrShortcut = "ocrShortcut"
        static let selectionShortcut = "selectionShortcut"
        static let audioShortcut = "audioShortcut"
        static let speechEngineID = "speechEngineID"
        static let audioSourceModeID = "audioSourceModeID"
        static let audioAppBundleID = "audioAppBundleID"
        static let audioAppName = "audioAppName"
        static let apiPath = "apiPath"
        static let apiMethod = "apiMethod"
        static let apiTextField = "apiTextField"
        static let apiTargetField = "apiTargetField"
        static let apiSourceField = "apiSourceField"
        static let apiResponsePath = "apiResponsePath"
        static let targetValueOverride = "targetValueOverride"
    }

    private let defaults = UserDefaults.standard

    @Published var translationEngineID: String {
        didSet { defaults.set(translationEngineID, forKey: Keys.translationEngine) }
    }

    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }

    @Published var targetLanguageID: String {
        didSet { defaults.set(targetLanguageID, forKey: Keys.targetLanguageID) }
    }

    @Published var sourceLanguageID: String {
        didSet { defaults.set(sourceLanguageID, forKey: Keys.sourceLanguageID) }
    }

    @Published var autoTranslate: Bool {
        didSet { defaults.set(autoTranslate, forKey: Keys.autoTranslate) }
    }

    @Published var ocrShortcut: HotKeyShortcut {
        didSet { store(ocrShortcut, key: Keys.ocrShortcut) }
    }

    @Published var selectionShortcut: HotKeyShortcut {
        didSet { store(selectionShortcut, key: Keys.selectionShortcut) }
    }

    @Published var audioShortcut: HotKeyShortcut {
        didSet { store(audioShortcut, key: Keys.audioShortcut) }
    }

    // MARK: - Audio / speech translation

    @Published var speechEngineID: String {
        didSet { defaults.set(speechEngineID, forKey: Keys.speechEngineID) }
    }

    @Published var audioSourceModeID: String {
        didSet { defaults.set(audioSourceModeID, forKey: Keys.audioSourceModeID) }
    }

    @Published var audioAppBundleID: String {
        didSet { defaults.set(audioAppBundleID, forKey: Keys.audioAppBundleID) }
    }

    @Published var audioAppName: String {
        didSet { defaults.set(audioAppName, forKey: Keys.audioAppName) }
    }

    // MARK: - Advanced API settings

    @Published var apiPath: String {
        didSet { defaults.set(apiPath, forKey: Keys.apiPath) }
    }

    @Published var apiMethod: String {
        didSet { defaults.set(apiMethod, forKey: Keys.apiMethod) }
    }

    @Published var apiTextField: String {
        didSet { defaults.set(apiTextField, forKey: Keys.apiTextField) }
    }

    @Published var apiTargetField: String {
        didSet { defaults.set(apiTargetField, forKey: Keys.apiTargetField) }
    }

    @Published var apiSourceField: String {
        didSet { defaults.set(apiSourceField, forKey: Keys.apiSourceField) }
    }

    @Published var apiResponsePath: String {
        didSet { defaults.set(apiResponsePath, forKey: Keys.apiResponsePath) }
    }

    @Published var targetValueOverride: String {
        didSet { defaults.set(targetValueOverride, forKey: Keys.targetValueOverride) }
    }

    init() {
        translationEngineID = defaults.string(forKey: Keys.translationEngine)
            ?? TranslationEngineKind.system.rawValue
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "http://192.168.3.3:5000"
        targetLanguageID = defaults.string(forKey: Keys.targetLanguageID) ?? "zh"
        sourceLanguageID = defaults.string(forKey: Keys.sourceLanguageID) ?? "auto"
        autoTranslate = defaults.object(forKey: Keys.autoTranslate) as? Bool ?? false
        ocrShortcut = Self.loadShortcut(defaults, key: Keys.ocrShortcut) ?? .ocrDefault
        selectionShortcut = Self.loadShortcut(defaults, key: Keys.selectionShortcut) ?? .selectionDefault
        audioShortcut = Self.loadShortcut(defaults, key: Keys.audioShortcut) ?? .audioDefault
        speechEngineID = defaults.string(forKey: Keys.speechEngineID) ?? SpeechEngineKind.apple.rawValue
        audioSourceModeID = defaults.string(forKey: Keys.audioSourceModeID) ?? AudioSourceMode.system.rawValue
        audioAppBundleID = defaults.string(forKey: Keys.audioAppBundleID) ?? ""
        audioAppName = defaults.string(forKey: Keys.audioAppName) ?? ""
        apiPath = defaults.string(forKey: Keys.apiPath) ?? ""
        apiMethod = defaults.string(forKey: Keys.apiMethod) ?? "POST"
        apiTextField = defaults.string(forKey: Keys.apiTextField) ?? ""
        apiTargetField = defaults.string(forKey: Keys.apiTargetField) ?? ""
        apiSourceField = defaults.string(forKey: Keys.apiSourceField) ?? ""
        apiResponsePath = defaults.string(forKey: Keys.apiResponsePath) ?? ""
        targetValueOverride = defaults.string(forKey: Keys.targetValueOverride) ?? ""
    }

    // MARK: - Derived values

    var translationEngine: TranslationEngineKind {
        TranslationEngineKind(rawValue: translationEngineID) ?? .system
    }

    var isSystemEngine: Bool {
        translationEngine == .system
    }

    var speechEngine: SpeechEngineKind {
        SpeechEngineKind(rawValue: speechEngineID) ?? .apple
    }

    var audioSourceMode: AudioSourceMode {
        AudioSourceMode(rawValue: audioSourceModeID) ?? .system
    }

    var audioSourceDescription: String {
        switch audioSourceMode {
        case .system:
            return "系统声音"
        case .application:
            return audioAppName.isEmpty ? "指定应用" : audioAppName
        case .microphone:
            return "麦克风"
        }
    }

    /// Maps the app's language identifiers to macOS Translation locale identifiers.
    func systemLanguageIdentifier(for id: String) -> String {
        Languages.visionCode(for: id) ?? id
    }

    var serverBaseURL: URL? {
        if let transientServerURL {
            return transientServerURL
        }
        var value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/docs", "/openapi.json"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }

    /// Used by the `--demo` developer flag; never persisted.
    var transientServerURL: URL?

    var targetLanguageName: String {
        Languages.name(for: targetLanguageID)
    }

    var effectiveTargetValue: String {
        let override = targetValueOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? apiLanguageCode(targetLanguageID) : override
    }

    var effectiveSourceValue: String? {
        sourceLanguageID == "auto" ? nil : apiLanguageCode(sourceLanguageID)
    }

    /// Maps the app's language identifiers to widely used API codes.
    /// LibreTranslate in particular uses `zh-Hans` / `zh-Hant`.
    private func apiLanguageCode(_ id: String) -> String {
        switch id {
        case "zh": return "zh-Hans"
        case "zh-TW": return "zh-Hant"
        default: return id
        }
    }

    var ocrLanguages: [String] {
        switch sourceLanguageID {
        case "auto":
            return ["zh-Hans", "zh-Hant", "en-US"]
        case "zh":
            return ["zh-Hans", "en-US"]
        case "zh-TW":
            return ["zh-Hant", "en-US"]
        default:
            if let code = Languages.visionCode(for: sourceLanguageID) {
                return [code, "en-US"]
            }
            return ["en-US"]
        }
    }

    var manualAPIConfiguration: APIConfiguration? {
        guard let baseURL = serverBaseURL else { return nil }
        let path = apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let textField = apiTextField.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetField = apiTargetField.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceField = apiSourceField.trimmingCharacters(in: .whitespacesAndNewlines)
        let responsePath = apiResponsePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .map(String.init)

        return APIConfiguration(
            baseURL: baseURL,
            path: path,
            method: apiMethod.uppercased() == "GET" ? "GET" : "POST",
            textField: textField.isEmpty ? "text" : textField,
            targetField: targetField.isEmpty ? nil : targetField,
            sourceField: sourceField.isEmpty ? nil : sourceField,
            sourceRequired: false,
            responsePath: responsePath,
            label: "\(apiMethod.uppercased() == "GET" ? "GET" : "POST") \(path)（手动配置）"
        )
    }

    func resetToDefaults() {
        translationEngineID = TranslationEngineKind.system.rawValue
        serverURL = "http://192.168.3.3:5000"
        targetLanguageID = "zh"
        sourceLanguageID = "auto"
        autoTranslate = false
        ocrShortcut = .ocrDefault
        selectionShortcut = .selectionDefault
        audioShortcut = .audioDefault
        speechEngineID = SpeechEngineKind.apple.rawValue
        audioSourceModeID = AudioSourceMode.system.rawValue
        audioAppBundleID = ""
        audioAppName = ""
        apiPath = ""
        apiMethod = "POST"
        apiTextField = ""
        apiTargetField = ""
        apiSourceField = ""
        apiResponsePath = ""
        targetValueOverride = ""
    }

    // MARK: - Storage helpers

    private func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadShortcut(_ defaults: UserDefaults, key: String) -> HotKeyShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
    }
}

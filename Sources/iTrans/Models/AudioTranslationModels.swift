import Foundation
import Speech

enum AudioSourceMode: String, CaseIterable, Identifiable {
    case system
    case application
    case microphone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "系统声音"
        case .application: return "指定应用"
        case .microphone: return "麦克风"
        }
    }
}

enum SpeechEngineKind: String, CaseIterable, Identifiable {
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "macOS 系统语音识别"
        }
    }

    var summary: String {
        switch self {
        case .apple:
            return "使用 Apple 端侧 SpeechAnalyzer 进行实时语音识别（需要 macOS 26 或更高版本）。"
        }
    }
}

enum SpeechLanguage {
    /// Maps the app's language identifiers to locales supported by SFSpeechRecognizer.
    static func localeIdentifier(for id: String) -> String {
        switch id {
        case "auto":
            let preferred = Locale.preferredLanguages.first ?? "en-US"
            return supportedLocale(matching: preferred)
        case "zh":
            return "zh-CN"
        case "zh-TW":
            return "zh-TW"
        case "en":
            return "en-US"
        case "ja":
            return "ja-JP"
        case "ko":
            return "ko-KR"
        case "fr":
            return "fr-FR"
        case "de":
            return "de-DE"
        case "es":
            return "es-ES"
        case "ru":
            return "ru-RU"
        case "pt":
            return "pt-BR"
        case "it":
            return "it-IT"
        default:
            return supportedLocale(matching: id)
        }
    }

    static func displayName(for id: String) -> String {
        if id == "auto" {
            return "自动（跟随系统）"
        }
        return Languages.name(for: id)
    }

    static func shortDisplayName(for id: String) -> String {
        if id == "auto" {
            return "自动"
        }
        return Languages.name(for: id)
    }

    private static func supportedLocale(matching identifier: String) -> String {
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(where: { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }) {
            return identifier
        }

        let language = Locale(identifier: identifier).language
        if let exact = supported.first(where: {
            $0.language.languageCode == language.languageCode && $0.language.script == language.script
        }) {
            return exact.identifier
        }
        if let loose = supported.first(where: { $0.language.languageCode == language.languageCode }) {
            return loose.identifier
        }
        return "en-US"
    }
}

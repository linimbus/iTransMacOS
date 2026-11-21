import Foundation
import NaturalLanguage

enum TranslationEngineKind: String, CaseIterable, Identifiable {
    case system
    case libretranslate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "macOS 系统翻译"
        case .libretranslate: return "LibreTranslate"
        }
    }

    var summary: String {
        switch self {
        case .system:
            return "使用 macOS 内置翻译引擎。首次翻译某个语言组合时，系统会提示下载语言包。"
        case .libretranslate:
            return "调用自建 LibreTranslate 服务，支持自动发现接口。"
        }
    }
}

enum LanguageDetector {
    /// Returns a BCP-47 style identifier such as `en` or `zh-Hans`.
    static func detectedLanguageIdentifier(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              language.rawValue != NLLanguage.undetermined.rawValue else {
            return nil
        }
        return language.rawValue
    }
}

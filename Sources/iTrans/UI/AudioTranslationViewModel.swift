import Foundation

@MainActor
final class AudioTranslationViewModel: ObservableObject {
    struct Segment: Identifiable {
        let id: Int
        let text: String
        var translation: String?
        var failure: String?
    }

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var partialText: String = ""
    @Published private(set) var liveTranslation: String = ""
    @Published var statusText: String = "准备中…"
    @Published var isListening: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var contentVersion: Int = 0

    @Published private(set) var sourceDescription: String = "系统声音"
    @Published private(set) var targetDescription: String = "简体中文"
    @Published private(set) var speechEngineName: String = "macOS 系统语音识别"

    private var nextID = 0

    func reset(source: String, target: String, speechEngine: String) {
        segments.removeAll()
        partialText = ""
        liveTranslation = ""
        errorMessage = nil
        statusText = "准备中…"
        isListening = false
        sourceDescription = source
        targetDescription = target
        speechEngineName = speechEngine
        nextID = 0
        contentVersion += 1
    }

    @discardableResult
    func appendSegment(_ text: String) -> Int {
        let segment = Segment(id: nextID, text: text, translation: nil, failure: nil)
        nextID += 1
        segments.append(segment)
        contentVersion += 1
        return segment.id
    }

    func setTranslation(_ text: String, for id: Int) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translation = text
        segments[index].failure = nil
        contentVersion += 1
    }

    func setTranslationFailure(_ message: String, for id: Int) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].failure = message
        contentVersion += 1
    }

    func setPartial(_ text: String) {
        guard text != partialText else { return }
        partialText = text
        contentVersion += 1
    }

    func setLiveTranslation(_ text: String) {
        guard text != liveTranslation else { return }
        liveTranslation = text
        contentVersion += 1
    }

    func clearPartial() {
        guard !partialText.isEmpty || !liveTranslation.isEmpty else { return }
        partialText = ""
        liveTranslation = ""
        contentVersion += 1
    }

    func markStarted(status: String) {
        isListening = true
        statusText = status
        errorMessage = nil
        contentVersion += 1
    }

    func markStopped() {
        isListening = false
        statusText = "已停止"
        contentVersion += 1
    }

    func setError(_ message: String) {
        errorMessage = message
        contentVersion += 1
    }

    // MARK: - Copy text

    var transcriptForCopy: String {
        var lines = segments.map(\.text)
        if !partialText.isEmpty {
            lines.append(partialText)
        }
        return lines.joined(separator: "\n")
    }

    var translationForCopy: String {
        var lines = segments.compactMap(\.translation)
        if !liveTranslation.isEmpty {
            lines.append(liveTranslation)
        }
        return lines.joined(separator: "\n")
    }
}

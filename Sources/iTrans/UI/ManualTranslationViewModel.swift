import Foundation

@MainActor
final class ManualTranslationViewModel: ObservableObject {
    enum Phase {
        case idle
        case loading
        case success
        case failure
    }

    @Published var inputText: String = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var translatedText: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var endpointDescription: String = ""

    /// Incremented by the window controller to move keyboard focus to the editor.
    @Published var focusRequest: Int = 0

    var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canTranslate: Bool {
        phase != .loading && !trimmedInput.isEmpty
    }

    var hasContent: Bool {
        !inputText.isEmpty || !translatedText.isEmpty || errorMessage != nil
    }

    func beginLoading() {
        phase = .loading
        errorMessage = nil
    }

    func finish(text: String, endpoint: String) {
        translatedText = text
        endpointDescription = endpoint
        errorMessage = nil
        phase = .success
    }

    func fail(_ message: String) {
        errorMessage = message
        phase = .failure
    }

    func clear() {
        inputText = ""
        translatedText = ""
        endpointDescription = ""
        errorMessage = nil
        phase = .idle
    }
}

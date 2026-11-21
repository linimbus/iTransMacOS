import AppKit
import Combine
import Foundation

@MainActor
final class AudioTranslationController {
    private let settings: AppSettings
    private let translator: TranslationService
    private let systemTranslator: SystemTranslationService

    private var windowController: AudioTranslationWindowController?
    private var model: AudioTranslationViewModel?
    private var capture: (any AudioCaptureLifecycle)?
    private var speech: SpeechRecognitionService?

    private var isListening = false
    private var sessionGeneration = 0

    private struct PendingTranslation {
        let id: Int
        let text: String
        let generation: Int
    }

    private var translationQueue: [PendingTranslation] = []
    private var translationWorker: Task<Void, Never>?
    private var liveTranslationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: AppSettings,
        translator: TranslationService,
        systemTranslator: SystemTranslationService
    ) {
        self.settings = settings
        self.translator = translator
        self.systemTranslator = systemTranslator

        settings.$sourceLanguageID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sourceLanguageDidChange()
                }
            }
            .store(in: &cancellables)
    }

    private func sourceLanguageDidChange() {
        guard isListening, windowController?.isVisible == true else { return }
        stopListening()
        sessionGeneration += 1
        beginCapture(generation: sessionGeneration)
    }

    var isWindowVisible: Bool {
        windowController?.isVisible == true
    }

    var isActive: Bool {
        isWindowVisible
    }

    /// Development helper used by `--demo-audio-window` for documentation screenshots.
    func showDemoWindow() {
        guard !isWindowVisible else { return }

        let model = AudioTranslationViewModel()
        model.reset(
            source: "系统声音",
            target: settings.targetLanguageName,
            speechEngine: settings.speechEngine.displayName
        )
        let samples: [(String, String)] = [
            ("Hello everyone.", "大家好。"),
            ("This is a live translation demo.", "这是一个实时翻译演示。"),
            ("The weather is nice today.", "今天天气很好。")
        ]
        for sample in samples {
            let id = model.appendSegment(sample.0)
            model.setTranslation(sample.1, for: id)
        }
        model.markStarted(status: "正在监听 · 系统声音")
        self.model = model

        let windowController = AudioTranslationWindowController()
        windowController.onClose = { [weak self] in self?.windowDidClose() }
        windowController.onStop = { [weak self] in self?.stopListening() }
        windowController.onStart = { [weak self] in self?.restartSession() }
        windowController.show(model: model, settings: settings)
        self.windowController = windowController
    }

    // MARK: - Toggle

    func toggle() {
        if isWindowVisible {
            windowController?.close()
        } else {
            startNewSession()
        }
    }

    // MARK: - Session lifecycle

    private func startNewSession() {
        guard !isWindowVisible else { return }

        sessionGeneration += 1
        let generation = sessionGeneration
        resetTranslationQueue()

        let model = AudioTranslationViewModel()
        model.reset(
            source: settings.audioSourceDescription,
            target: settings.targetLanguageName,
            speechEngine: settings.speechEngine.displayName
        )
        self.model = model

        let windowController = AudioTranslationWindowController()
        windowController.onClose = { [weak self] in self?.windowDidClose() }
        windowController.onStop = { [weak self] in self?.stopListening() }
        windowController.onStart = { [weak self] in self?.restartSession() }
        windowController.show(model: model, settings: settings)
        self.windowController = windowController

        beginCapture(generation: generation)
    }

    private func restartSession() {
        guard let model else { return }
        stopListening()
        sessionGeneration += 1
        let generation = sessionGeneration
        resetTranslationQueue()
        model.reset(
            source: settings.audioSourceDescription,
            target: settings.targetLanguageName,
            speechEngine: settings.speechEngine.displayName
        )
        beginCapture(generation: generation)
    }

    private func beginCapture(generation: Int) {
        guard let model, generation == sessionGeneration else { return }

        model.statusText = "准备中…"
        model.isListening = false

        let usesMicrophone = settings.audioSourceMode == .microphone

        if usesMicrophone {
            if !PermissionManager.microphoneGranted {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            if !PermissionManager.screenRecordingGranted {
                NSApp.activate(ignoringOtherApps: true)
            }

            if !PermissionManager.screenRecordingGranted, !PermissionManager.requestScreenRecording() {
                model.statusText = "无法开始"
                model.setError("需要“屏幕录制”权限才能捕获系统音频。请前往 系统设置 → 隐私与安全性 → 屏幕录制 勾选 iTrans，然后重新启动应用。")
                return
            }
        }

        Task { @MainActor [weak self] in
            guard let self, generation == self.sessionGeneration, self.model === model else { return }

            do {
                let source: AudioCaptureSource?
                if usesMicrophone {
                    var granted = PermissionManager.microphoneGranted
                    if !granted {
                        granted = await PermissionManager.requestMicrophoneAccess()
                    }
                    guard granted else { throw MicrophoneCaptureError.notAuthorized }
                    source = nil
                } else {
                    source = try self.resolveAudioSource()
                }

                let speech = SpeechRecognitionService()
                speech.onPartial = { [weak self] text in
                    self?.handlePartial(text, generation: generation)
                }
                speech.onFinal = { [weak self] text in
                    self?.handleFinal(text, generation: generation)
                }
                speech.onStatus = { [weak self] status in
                    guard let self, generation == self.sessionGeneration, self.isListening else { return }
                    self.model?.statusText = status
                }
                speech.onError = { [weak self] error in
                    self?.handleSpeechError(error, generation: generation)
                }

                try await speech.start(
                    localeIdentifier: SpeechLanguage.localeIdentifier(for: self.settings.sourceLanguageID)
                )

                let capture: any AudioCaptureLifecycle
                let sourceLabel: String

                if usesMicrophone {
                    let microphone = MicrophoneCaptureService()
                    try microphone.start(
                        onAudio: { buffer in
                            speech.appendPCM(buffer)
                        },
                        onError: { [weak self] error in
                            DispatchQueue.main.async {
                                self?.handleCaptureError(error, generation: generation)
                            }
                        }
                    )
                    capture = microphone
                    sourceLabel = "麦克风（\(microphone.deviceName)）"
                } else {
                    guard let source else {
                        throw AudioCaptureError.noDisplay
                    }
                    let systemCapture = SystemAudioCaptureService()
                    try await systemCapture.start(
                        source: source,
                        onAudio: { buffer in
                            speech.append(buffer)
                        },
                        onError: { [weak self] error in
                            DispatchQueue.main.async {
                                self?.handleCaptureError(error, generation: generation)
                            }
                        }
                    )
                    capture = systemCapture
                    sourceLabel = source.displayName
                }

                guard generation == self.sessionGeneration, self.model === model else {
                    speech.stop()
                    Task { await capture.stop() }
                    return
                }

                self.speech = speech
                self.capture = capture
                self.isListening = true
                model.markStarted(status: "正在监听 · \(sourceLabel)")
                AppLog.app.info("Audio translation started: \(sourceLabel, privacy: .public)")
            } catch {
                guard generation == self.sessionGeneration, self.model === model else { return }
                self.isListening = false
                self.speech?.stop()
                self.speech = nil
                model.isListening = false
                model.statusText = "无法开始"
                model.setError(self.message(for: error))
                NSApp.activate(ignoringOtherApps: true)
                AppLog.app.error("Audio translation failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopListening() {
        guard isListening else {
            model?.markStopped()
            return
        }

        isListening = false
        liveTranslationTask?.cancel()
        liveTranslationTask = nil

        // Preserve the last visible partial line as a final segment.
        if let model, !model.partialText.isEmpty {
            let partial = model.partialText
            model.clearPartial()
            let id = model.appendSegment(partial)
            enqueueTranslation(id: id, text: partial, generation: sessionGeneration)
        }

        let capture = self.capture
        let speech = self.speech
        self.capture = nil
        self.speech = nil

        Task { await capture?.stop() }
        speech?.stop()

        model?.markStopped()
        AppLog.app.info("Audio translation stopped")
    }

    private func windowDidClose() {
        sessionGeneration += 1
        isListening = false

        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        translationWorker?.cancel()
        translationWorker = nil
        translationQueue.removeAll()

        let capture = self.capture
        let speech = self.speech
        self.capture = nil
        self.speech = nil

        Task { await capture?.stop() }
        speech?.stop()

        windowController = nil
        model = nil
        AppLog.app.info("Audio translation window closed")
    }

    // MARK: - Speech callbacks

    private func handlePartial(_ text: String, generation: Int) {
        guard generation == sessionGeneration, isListening, let model else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.setPartial(trimmed)
        scheduleLiveTranslation(for: trimmed, generation: generation)
    }

    private func handleFinal(_ text: String, generation: Int) {
        guard generation == sessionGeneration, isListening, let model else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            model.clearPartial()
            return
        }

        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        model.clearPartial()
        let id = model.appendSegment(trimmed)
        enqueueTranslation(id: id, text: trimmed, generation: generation)
    }

    private func handleSpeechError(_ error: Error, generation: Int) {
        guard generation == sessionGeneration, isListening, let model else { return }
        isListening = false
        liveTranslationTask?.cancel()
        liveTranslationTask = nil

        let capture = self.capture
        let speech = self.speech
        self.capture = nil
        self.speech = nil
        Task { await capture?.stop() }
        speech?.stop()

        model.isListening = false
        model.statusText = "语音识别已停止"
        model.setError(message(for: error))
        AppLog.app.error("Speech recognition error: \(error.localizedDescription, privacy: .public)")
    }

    private func handleCaptureError(_ error: Error, generation: Int) {
        guard generation == sessionGeneration, isListening, let model else { return }
        isListening = false
        liveTranslationTask?.cancel()
        liveTranslationTask = nil

        self.capture = nil
        let speech = self.speech
        self.speech = nil
        speech?.stop()

        model.isListening = false
        model.statusText = "音频捕获已停止"
        model.setError(message(for: error))
        AppLog.app.error("Audio capture error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Live translation

    private func scheduleLiveTranslation(for text: String, generation: Int) {
        liveTranslationTask?.cancel()
        guard text.count >= 2 else {
            model?.setLiveTranslation("")
            return
        }

        liveTranslationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self,
                  !Task.isCancelled,
                  generation == self.sessionGeneration,
                  self.isListening,
                  self.model?.partialText == text else { return }

            do {
                let translated = try await self.translate(text)
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      self.isListening,
                      self.model?.partialText == text else { return }
                self.model?.setLiveTranslation(translated)
            } catch {
                // Live preview errors are silent; finalized segments surface errors.
            }
        }
    }

    // MARK: - Queued translation

    private func enqueueTranslation(id: Int, text: String, generation: Int) {
        translationQueue.append(PendingTranslation(id: id, text: text, generation: generation))
        if translationWorker == nil {
            startTranslationWorker()
        }
    }

    private func startTranslationWorker() {
        translationWorker = Task { @MainActor [weak self] in
            guard let self else { return }

            while !self.translationQueue.isEmpty {
                let item = self.translationQueue.removeFirst()
                guard item.generation == self.sessionGeneration else { continue }

                do {
                    let translated = try await self.translate(item.text)
                    guard item.generation == self.sessionGeneration else { continue }
                    self.model?.setTranslation(translated, for: item.id)
                    self.model?.errorMessage = nil
                } catch {
                    guard item.generation == self.sessionGeneration else { continue }
                    let message = self.message(for: error)
                    self.model?.setTranslationFailure(message, for: item.id)
                    if self.model?.errorMessage == nil {
                        self.model?.setError(message)
                    }
                }
            }

            self.translationWorker = nil
            if !self.translationQueue.isEmpty {
                self.startTranslationWorker()
            }
        }
    }

    private func resetTranslationQueue() {
        translationWorker?.cancel()
        translationWorker = nil
        translationQueue.removeAll()
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
    }

    // MARK: - Translation routing

    private func translate(_ text: String) async throws -> String {
        let sourceID = settings.sourceLanguageID

        if settings.isSystemEngine {
            return try await systemTranslator.translateSilently(
                text: text,
                sourceLanguageID: sourceID,
                targetLanguageID: settings.targetLanguageID
            )
        }

        let result = try await translator.translate(text: text, settings: settings)
        return result.text
    }

    // MARK: - Helpers

    private func resolveAudioSource() throws -> AudioCaptureSource {
        switch settings.audioSourceMode {
        case .system:
            return .system
        case .application:
            let bundleID = settings.audioAppBundleID
            guard !bundleID.isEmpty else { throw AudioCaptureError.appNotSelected }
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID
            }) else {
                throw AudioCaptureError.appNotRunning(
                    settings.audioAppName.isEmpty ? bundleID : settings.audioAppName
                )
            }
            return .application(
                bundleID: bundleID,
                name: app.localizedName ?? settings.audioAppName
            )
        case .microphone:
            throw MicrophoneCaptureError.noInputDevice
        }
    }

    private func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

}

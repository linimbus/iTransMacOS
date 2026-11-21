import AppKit
import SwiftUI
import Translation

enum SystemTranslationError: LocalizedError {
    case unsupportedOS
    case unsupportedLanguagePair(String)
    case unableToIdentifyLanguage
    case languagePackRequired
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "macOS 系统翻译需要 macOS 15 或更高版本。"
        case .unsupportedLanguagePair(let detail):
            let suffix = detail.isEmpty ? "" : "（\(detail)）"
            return "macOS 系统翻译不支持该语言组合\(suffix)。可在设置中切换为 LibreTranslate。"
        case .unableToIdentifyLanguage:
            return "无法识别源语言，请在设置中手动指定源语言。"
        case .languagePackRequired:
            return "macOS 系统翻译语言包尚未安装。请在系统提示中下载语言包，或在设置中切换为 LibreTranslate。"
        case .cancelled:
            return "系统翻译已取消。"
        case .failed(let message):
            return "macOS 系统翻译失败：\(message)"
        }
    }
}

/// Uses Apple's on-device Translation framework with a small preparation window.
/// The window is necessary for the system language-pack download prompt.
@MainActor
final class SystemTranslationService: NSObject, NSWindowDelegate {
    private var workerWindow: NSWindow?
    private var workerModel: SystemTranslationWorkerModel?
    private var continuation: CheckedContinuation<String, Error>?
    private var isClosingWorker = false

    func translate(
        text: String,
        sourceLanguageID: String,
        targetLanguageID: String,
        anchor: NSPoint
    ) async throws -> String {
        cancelCurrent()

        guard #available(macOS 15.0, *) else {
            throw SystemTranslationError.unsupportedOS
        }

        let target = Locale.Language(identifier: systemLanguageIdentifier(for: targetLanguageID))
        let source: Locale.Language?
        if sourceLanguageID == "auto" {
            if let detected = LanguageDetector.detectedLanguageIdentifier(for: text) {
                source = Locale.Language(identifier: detected)
            } else {
                source = nil
            }
        } else {
            source = Locale.Language(identifier: systemLanguageIdentifier(for: sourceLanguageID))
        }

        if let source, source.maximalIdentifier == target.maximalIdentifier {
            return text
        }

        if let source, #available(macOS 26.0, *) {
            let status = await LanguageAvailability().status(from: source, to: target)
            switch status {
            case .installed:
                do {
                    let session = TranslationSession(installedSource: source, target: target)
                    let response = try await session.translate(text)
                    return response.targetText
                } catch {
                    if TranslationError.notInstalled ~= error {
                        return try await runWorker(text: text, source: source, target: target, anchor: anchor)
                    }
                    throw mapError(error)
                }
            case .supported:
                return try await runWorker(text: text, source: source, target: target, anchor: anchor)
            case .unsupported:
                throw SystemTranslationError.unsupportedLanguagePair("")
            @unknown default:
                return try await runWorker(text: text, source: source, target: target, anchor: anchor)
            }
        }

        return try await runWorker(text: text, source: source, target: target, anchor: anchor)
    }

    /// Translation without any preparation window. Used for live audio translation.
    /// Requires the corresponding system language pack to already be installed.
    func translateSilently(
        text: String,
        sourceLanguageID: String,
        targetLanguageID: String
    ) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw SystemTranslationError.unsupportedOS
        }

        let target = Locale.Language(identifier: systemLanguageIdentifier(for: targetLanguageID))
        let source: Locale.Language
        if sourceLanguageID == "auto" {
            guard let detected = LanguageDetector.detectedLanguageIdentifier(for: text) else {
                throw SystemTranslationError.unableToIdentifyLanguage
            }
            source = Locale.Language(identifier: detected)
        } else {
            source = Locale.Language(identifier: systemLanguageIdentifier(for: sourceLanguageID))
        }

        if source.maximalIdentifier == target.maximalIdentifier {
            return text
        }

        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            let session = TranslationSession(installedSource: source, target: target)
            let response = try await session.translate(text)
            return response.targetText
        case .supported:
            throw SystemTranslationError.languagePackRequired
        case .unsupported:
            throw SystemTranslationError.unsupportedLanguagePair("")
        @unknown default:
            throw SystemTranslationError.failed("无法确定系统翻译状态")
        }
    }

    func cancelCurrent() {
        guard let continuation else {
            closeWorkerWindow()
            return
        }
        self.continuation = nil
        closeWorkerWindow()
        continuation.resume(throwing: SystemTranslationError.cancelled)
    }

    // MARK: - Worker

    private func runWorker(
        text: String,
        source: Locale.Language?,
        target: Locale.Language,
        anchor: NSPoint
    ) async throws -> String {
        guard #available(macOS 15.0, *) else {
            throw SystemTranslationError.unsupportedOS
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let model = SystemTranslationWorkerModel(text: text, source: source, target: target)
            model.onFinish = { [weak self] result in
                self?.finishWorker(result)
            }
            model.onCancel = { [weak self] in
                self?.cancelCurrent()
            }
            self.workerModel = model

            presentWorkerWindow(model: model, anchor: anchor)
        }
    }

    @available(macOS 15.0, *)
    private func presentWorkerWindow(model: SystemTranslationWorkerModel, anchor: NSPoint) {
        let view = SystemTranslationWorkerView(model: model)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macOS 系统翻译"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        window.setContentSize(NSSize(width: 400, height: 150))
        positionWorker(window, near: anchor)

        workerWindow = window
        isClosingWorker = false

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func positionWorker(_ window: NSWindow, near point: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size

        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + 40
        window.setFrameOrigin(NSPoint(
            x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8),
            y: min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        ))
    }

    private func finishWorker(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil

        let mapped: Error
        switch result {
        case .success(let text):
            closeWorkerWindow()
            continuation.resume(returning: text)
            return
        case .failure(let error):
            if #available(macOS 15.0, *) {
                mapped = mapError(error)
            } else {
                mapped = error
            }
        }

        closeWorkerWindow()
        continuation.resume(throwing: mapped)
    }

    private func closeWorkerWindow() {
        guard let window = workerWindow else { return }
        workerWindow = nil
        workerModel = nil
        isClosingWorker = true
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        isClosingWorker = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosingWorker,
              let window = notification.object as? NSWindow,
              window === workerWindow else { return }
        cancelCurrent()
    }

    // MARK: - Helpers

    private func systemLanguageIdentifier(for id: String) -> String {
        Languages.visionCode(for: id) ?? id
    }

    @available(macOS 15.0, *)
    private func mapError(_ error: Error) -> Error {
        if error is CancellationError {
            return SystemTranslationError.cancelled
        }
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            return SystemTranslationError.languagePackRequired
        }
        if TranslationError.unsupportedLanguagePairing ~= error {
            return SystemTranslationError.unsupportedLanguagePair("")
        }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return SystemTranslationError.unableToIdentifyLanguage
        }
        if TranslationError.nothingToTranslate ~= error {
            return SystemTranslationError.failed("没有可翻译的文本")
        }
        if TranslationError.internalError ~= error {
            return SystemTranslationError.failed("语言包下载失败或系统翻译服务暂不可用。请在系统提示中重试下载，或在设置中切换为 LibreTranslate。")
        }
        if #available(macOS 26.0, *), TranslationError.alreadyCancelled ~= error {
            return SystemTranslationError.cancelled
        }
        if TranslationError.unsupportedSourceLanguage ~= error {
            return SystemTranslationError.unsupportedLanguagePair("源语言不受支持")
        }
        if TranslationError.unsupportedTargetLanguage ~= error {
            return SystemTranslationError.unsupportedLanguagePair("目标语言不受支持")
        }
        return SystemTranslationError.failed(error.localizedDescription)
    }
}

@MainActor
final class SystemTranslationWorkerModel: ObservableObject {
    let text: String
    let source: Locale.Language?
    let target: Locale.Language

    @Published var statusText = "正在准备 macOS 系统翻译…"
    @Published var detailText = "首次翻译该语言组合时，系统会提示下载语言包。"

    var onFinish: ((Result<String, Error>) -> Void)?
    var onCancel: (() -> Void)?

    private var didFinish = false

    init(text: String, source: Locale.Language?, target: Locale.Language) {
        self.text = text
        self.source = source
        self.target = target
    }

    @available(macOS 15.0, *)
    func run(session: TranslationSession) async {
        guard !didFinish else { return }

        do {
            detailText = "如系统提示下载语言包，请按提示完成下载；下载完成后会自动继续。"
            try await session.prepareTranslation()
            guard !didFinish else { return }

            statusText = "正在使用 macOS 系统翻译…"
            detailText = "翻译完成后会在鼠标附近显示结果。"
            let response = try await session.translate(text)
            finish(.success(response.targetText))
        } catch {
            finish(.failure(error))
        }
    }

    func finish(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(result)
    }

    func cancel() {
        onCancel?()
    }
}

@available(macOS 15.0, *)
struct SystemTranslationWorkerView: View {
    @ObservedObject var model: SystemTranslationWorkerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(model.statusText)
                    .font(.system(size: 13, weight: .medium))
            }

            Text(model.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") {
                    model.cancel()
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 400, height: 150, alignment: .leading)
        .translationTask(source: model.source, target: model.target) { session in
            await model.run(session: session)
        }
    }
}

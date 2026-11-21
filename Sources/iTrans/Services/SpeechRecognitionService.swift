import AVFoundation
import CoreMedia
import Foundation
import Speech

enum SpeechRecognitionError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case modelUnavailable(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "macOS 语音识别服务当前不可用，请稍后重试。"
        case .unsupportedLocale(let identifier):
            return "系统语音识别不支持语言 \(identifier)。"
        case .modelUnavailable(let detail):
            return "语音识别模型不可用：\(detail)"
        case .startFailed(let message):
            return "无法启动语音识别：\(message)"
        }
    }
}

/// Streams audio buffers into Apple's on-device SpeechAnalyzer / SpeechTranscriber.
/// Requires macOS 26 or newer.
final class SpeechRecognitionService {
    private let stateQueue = DispatchQueue(label: "com.linimbus.itrans.speech", qos: .userInitiated)

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var isRunning = false

    // macOS 27+ converter; kept as AnyObject to allow a macOS 26 fallback.
    private var analyzerInputConverter: AnyObject?
    private var fallbackConverter: AVAudioConverter?
    private var fallbackOutputFormat: AVAudioFormat?

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?

    func start(localeIdentifier: String) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecognitionError.unavailable
        }

        let requested = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw SpeechRecognitionError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported {
            throw SpeechRecognitionError.unsupportedLocale(localeIdentifier)
        }
        if status != .installed {
            emitStatus("正在准备语音识别模型…")
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(240)
        )

        var converter: AnyObject?
        if #available(macOS 27.0, *) {
            converter = try? await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        }
        let outputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        stateQueue.sync {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.inputContinuation = continuation
            self.analyzerInputConverter = converter
            self.fallbackOutputFormat = outputFormat
            self.fallbackConverter = nil
            self.isRunning = true
        }

        resultsTask = Task { [weak self, weak transcriber] in
            guard let self, let transcriber else { return }
            do {
                for try await result in transcriber.results {
                    guard self.isRunning else { break }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        self.emitFinal(text)
                    } else {
                        self.emitPartial(text)
                    }
                }
            } catch {
                if self.isRunning {
                    self.emitError(SpeechRecognitionError.startFailed(error.localizedDescription))
                }
            }
        }

        analyzerTask = Task { [weak self, analyzer] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                guard let self, self.isRunning else { return }
                self.emitError(SpeechRecognitionError.startFailed(error.localizedDescription))
            }
        }

        AppLog.app.info("SpeechAnalyzer started for \(locale.identifier, privacy: .public)")
    }

    func stop() {
        stateQueue.async {
            guard self.isRunning else { return }
            self.isRunning = false

            let analyzer = self.analyzer
            self.inputContinuation?.finish()
            self.inputContinuation = nil
            self.analyzer = nil
            self.transcriber = nil
            self.analyzerInputConverter = nil
            self.fallbackConverter = nil
            self.fallbackOutputFormat = nil

            self.resultsTask?.cancel()
            self.resultsTask = nil
            self.analyzerTask?.cancel()
            self.analyzerTask = nil

            Task {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            }
        }
    }

    /// Kept for interface compatibility. SpeechAnalyzer finalizes utterances on its own.
    func finalizeCurrentUtterance() {}

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        enqueuePCMBuffer(buffer)
    }

    /// Accepts microphone buffers. The buffer is copied because AVAudioEngine
    /// reuses its tap buffers after the callback returns.
    func appendPCM(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copyPCMBuffer(buffer) else { return }
        enqueuePCMBuffer(copy)
    }

    private func enqueuePCMBuffer(_ buffer: AVAudioPCMBuffer) {
        stateQueue.async {
            guard self.isRunning, let continuation = self.inputContinuation else { return }

            if #available(macOS 27.0, *),
               let converter = self.analyzerInputConverter as? AnalyzerInputConverter {
                do {
                    let inputs = try converter.convert(buffer, at: nil)
                    for input in inputs {
                        continuation.yield(input)
                    }
                } catch {
                    // Drop a bad buffer rather than aborting the session.
                }
                return
            }

            self.appendWithFallbackConverter(buffer, continuation: continuation)
        }
    }

    // MARK: - Audio conversion (macOS 26 fallback)

    private func appendWithFallbackConverter(
        _ buffer: AVAudioPCMBuffer,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        guard let outputFormat = fallbackOutputFormat else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        let needsConversion = buffer.format.sampleRate != outputFormat.sampleRate
            || buffer.format.channelCount != outputFormat.channelCount
            || buffer.format.commonFormat != outputFormat.commonFormat

        guard needsConversion else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        if fallbackConverter == nil {
            fallbackConverter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter = fallbackConverter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status != .error, converted.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in 0..<source.count {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else { continue }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
        }
        return copy
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    // MARK: - Emitters

    private func emitPartial(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onPartial?(text)
        }
    }

    private func emitFinal(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFinal?(text)
        }
    }

    private func emitError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    private func emitStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(status)
        }
    }
}

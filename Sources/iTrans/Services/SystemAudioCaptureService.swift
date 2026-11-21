import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import os

struct AudioCaptureSource {
    enum Kind {
        case system
        case application(bundleID: String, name: String)
    }

    let kind: Kind

    var displayName: String {
        switch kind {
        case .system:
            return "系统声音"
        case .application(_, let name):
            return name
        }
    }

    static let system = AudioCaptureSource(kind: .system)

    static func application(bundleID: String, name: String) -> AudioCaptureSource {
        AudioCaptureSource(kind: .application(bundleID: bundleID, name: name))
    }
}

enum AudioCaptureError: LocalizedError {
    case noDisplay
    case appNotRunning(String)
    case appNotSelected
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "没有找到可用的显示器。"
        case .appNotRunning(let name):
            return "应用“\(name)”当前没有运行，请先打开它，再到设置中刷新应用列表。"
        case .appNotSelected:
            return "请先在设置中选择要监听的音频来源应用。"
        case .startFailed(let message):
            return "无法开始捕获系统音频：\(message)"
        }
    }
}

/// Captures system audio (or a single application's audio) with ScreenCaptureKit.
final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, AudioCaptureLifecycle {
    private struct CaptureState {
        var stream: SCStream?
        var onAudio: ((CMSampleBuffer) -> Void)?
        var onError: ((Error) -> Void)?
        var isCapturing = false
    }

    private let state = OSAllocatedUnfairLock(initialState: CaptureState())

    private let audioQueue = DispatchQueue(
        label: "com.linimbus.itrans.audio-capture",
        qos: .userInitiated
    )

    func start(
        source: AudioCaptureSource,
        onAudio: @escaping (CMSampleBuffer) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        guard !isActive else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = preferredDisplay(from: content) else {
            throw AudioCaptureError.noDisplay
        }

        let filter: SCContentFilter
        switch source.kind {
        case .system:
            filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
        case .application(let bundleID, let name):
            guard let application = content.applications.first(where: {
                $0.bundleIdentifier == bundleID
            }) else {
                throw AudioCaptureError.appNotRunning(name)
            }
            filter = SCContentFilter(
                display: display,
                including: [application],
                exceptingWindows: []
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 1
        configuration.showsCursor = false
        // Audio-only usage still needs a valid video configuration.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        state.withLock { state in
            state.stream = stream
            state.onAudio = onAudio
            state.onError = onError
            state.isCapturing = true
        }

        do {
            try await stream.startCapture()
            AppLog.capture.info("Audio capture started: \(source.displayName, privacy: .public)")
        } catch {
            state.withLock { state in
                state.isCapturing = false
                state.stream = nil
                state.onAudio = nil
                state.onError = nil
            }
            throw AudioCaptureError.startFailed(error.localizedDescription)
        }
    }

    func stop() async {
        let stream = state.withLock { state -> SCStream? in
            guard state.isCapturing else { return nil }
            state.isCapturing = false
            let stream = state.stream
            state.stream = nil
            state.onAudio = nil
            state.onError = nil
            return stream
        }

        try? await stream?.stopCapture()
    }

    private var isActive: Bool {
        state.withLock { $0.isCapturing }
    }

    private func preferredDisplay(from content: SCShareableContent) -> SCDisplay? {
        if let screen = NSScreen.main, let id = screen.displayID,
           let display = content.displays.first(where: { $0.displayID == id }) {
            return display
        }
        return content.displays.first
    }

    private func handler() -> ((CMSampleBuffer) -> Void)? {
        state.withLock { $0.onAudio }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler()?(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.capture.error("Audio capture stopped: \(error.localizedDescription, privacy: .public)")
        let handler = state.withLock { state -> ((Error) -> Void)? in
            guard state.isCapturing else { return nil }
            state.isCapturing = false
            state.stream = nil
            return state.onError
        }
        handler?(AudioCaptureError.startFailed(error.localizedDescription))
    }
}

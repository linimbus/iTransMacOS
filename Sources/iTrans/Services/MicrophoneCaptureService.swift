import AVFoundation
import Foundation

enum MicrophoneCaptureError: LocalizedError {
    case notAuthorized
    case noInputDevice
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "需要“麦克风”权限才能录制语音。请前往 系统设置 → 隐私与安全性 → 麦克风 勾选 iTrans。"
        case .noInputDevice:
            return "没有找到可用的麦克风输入设备。"
        case .startFailed(let message):
            return "无法启动麦克风：\(message)"
        }
    }
}

protocol AudioCaptureLifecycle: AnyObject {
    func stop() async
}

/// Captures the default microphone with AVAudioEngine.
final class MicrophoneCaptureService: AudioCaptureLifecycle {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?
    private var onError: ((Error) -> Void)?

    var deviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认麦克风"
    }

    func start(
        onAudio: @escaping (AVAudioPCMBuffer) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        guard !isRunning else { return }
        guard PermissionManager.microphoneGranted else {
            throw MicrophoneCaptureError.notAuthorized
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MicrophoneCaptureError.noInputDevice
        }

        self.onError = onError

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onAudio(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw MicrophoneCaptureError.startFailed(error.localizedDescription)
        }

        isRunning = true

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onError?(MicrophoneCaptureError.startFailed("音频输入设备发生变化"))
        }

        AppLog.capture.info("Microphone capture started: \(self.deviceName, privacy: .public)")
    }

    func stop() async {
        guard isRunning || tapInstalled else { return }
        isRunning = false

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        engine.stop()
        onError = nil
    }
}

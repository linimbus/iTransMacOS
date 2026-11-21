import AppKit
import SwiftUI

@MainActor
struct AudioTranslationView: View {
    @ObservedObject var model: AudioTranslationViewModel
    @ObservedObject var settings: AppSettings

    var onStop: () -> Void
    var onStart: () -> Void
    var onClose: () -> Void
    var onOpenPrivacySettings: () -> Void

    @State private var copiedTranscript = false
    @State private var copiedTranslation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage {
                errorBanner(error)
                Divider()
            }
            transcriptPane
            Divider()
            translationPane
        }
        .padding(14)
        .frame(
            minWidth: 520,
            maxWidth: .infinity,
            minHeight: 360,
            maxHeight: .infinity
        )
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            resizeGrip
                .padding(.trailing, 9)
                .padding(.bottom, 9)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isListening ? Color.red : Color.secondary.opacity(0.6))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusText)
                    .font(.system(size: 12, weight: .semibold))
                Text(model.sourceDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)

            Spacer()

            HStack(spacing: 5) {
                Text("音频语言")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)

                Menu {
                    ForEach(Languages.sources) { language in
                        Button {
                            settings.sourceLanguageID = language.id
                        } label: {
                            if settings.sourceLanguageID == language.id {
                                Label(SpeechLanguage.displayName(for: language.id), systemImage: "checkmark")
                            } else {
                                Text(SpeechLanguage.displayName(for: language.id))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(SpeechLanguage.shortDisplayName(for: settings.sourceLanguageID))
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("音频语言与 OCR 源语言共用同一设置；修改后会自动重新开始识别")
            }

            targetLanguageMenu

            Button(model.isListening ? "停止" : "开始") {
                if model.isListening {
                    onStop()
                } else {
                    onStart()
                }
            }
            .controlSize(.small)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .background(WindowDragArea())
        .padding(.vertical, -2)
        .contentShape(Rectangle())
    }

    private var targetLanguageMenu: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)

            Menu {
                ForEach(Languages.targets) { language in
                    Button {
                        settings.targetLanguageID = language.id
                    } label: {
                        if settings.targetLanguageID == language.id {
                            Label(language.name, systemImage: "checkmark")
                        } else {
                            Text(language.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(settings.targetLanguageName)
                        .font(.system(size: 10.5, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("目标语言")
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            Text(error)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("打开隐私设置", action: onOpenPrivacySettings)
                .controlSize(.small)

            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Transcript

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(
                title: "实时转写",
                icon: "waveform",
                trailing: model.segments.isEmpty ? "" : "\(model.segments.count) 段",
                copyText: model.transcriptForCopy,
                copied: $copiedTranscript,
                copyHelp: "拷贝全部转写"
            )
            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.segments.isEmpty && model.partialText.isEmpty {
                            emptyHint("开始播放会议或浏览器音频后，转写内容会显示在这里。")
                        }

                        ForEach(model.segments) { segment in
                            Text(segment.text)
                                .font(.system(size: 15))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !model.partialText.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text(model.partialText)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .onChange(of: model.contentVersion) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Translation

    private var translationPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(
                title: "实时翻译",
                icon: "character.bubble",
                trailing: settings.targetLanguageName,
                copyText: model.translationForCopy,
                copied: $copiedTranslation,
                copyHelp: "拷贝全部译文"
            )
            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.segments.isEmpty && model.liveTranslation.isEmpty {
                            emptyHint("翻译结果会实时显示在这里。")
                        }

                        ForEach(model.segments) { segment in
                            if let translation = segment.translation {
                                Text(translation)
                                    .font(.system(size: 15.5))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if let failure = segment.failure {
                                Label(failure, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("正在翻译…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if !model.liveTranslation.isEmpty {
                            Text(model.liveTranslation)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear.frame(height: 1).id("translation-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .onChange(of: model.contentVersion) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("translation-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func paneHeader(
        title: String,
        icon: String,
        trailing: String,
        copyText: String,
        copied: Binding<Bool>,
        copyHelp: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Button {
                copyToPasteboard(copyText, copied: copied)
            } label: {
                Label(
                    copied.wrappedValue ? "已拷贝" : "拷贝",
                    systemImage: copied.wrappedValue ? "checkmark" : "doc.on.doc"
                )
                .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied.wrappedValue ? Color.green : Color.secondary)
            .disabled(copyText.isEmpty)
            .opacity(copyText.isEmpty ? 0.35 : 1)
            .help(copyHelp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
    }

    private func copyToPasteboard(_ text: String, copied: Binding<Bool>) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied.wrappedValue = false
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }

    /// Subtle affordance hinting that the window can be resized from its corner.
    private var resizeGrip: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: CGFloat(4 + index * 4), height: 1.2)
            }
        }
        .padding(6)
        .allowsHitTesting(false)
    }
}

import AppKit
import SwiftUI

@MainActor
struct AudioTranslationView: View {
    @ObservedObject var model: AudioTranslationViewModel

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
        .frame(minWidth: 520, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
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

            Spacer()

            Text("\(model.speechEngineName) · \(model.targetDescription)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Button(model.isListening ? "停止" : "开始") {
                if model.isListening {
                    onStop()
                } else {
                    onStart()
                }
            }
            .controlSize(.small)

            Button("关闭", action: onClose)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                trailing: model.targetDescription,
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
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
}

import AppKit
import SwiftUI

@MainActor
struct ManualTranslationView: View {
    @ObservedObject var model: ManualTranslationViewModel
    @ObservedObject var settings: AppSettings

    var onTranslate: () -> Void
    var onClose: () -> Void
    var onClear: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            inputPane
            Divider()
            outputPane
            Divider()
            footer
        }
        .padding(14)
        .frame(
            minWidth: 480,
            maxWidth: .infinity,
            minHeight: 340,
            maxHeight: .infinity
        )
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .onAppear { inputFocused = true }
        .onExitCommand(perform: onClose)
        .onChange(of: model.focusRequest) { _, _ in
            inputFocused = true
        }
        .onChange(of: settings.targetLanguageID) { _, _ in
            retranslateIfNeeded()
        }
        .onChange(of: settings.sourceLanguageID) { _, _ in
            retranslateIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)

            Text("手动翻译")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)

            Spacer()

            sourceLanguageMenu

            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)

            targetLanguageMenu

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .background(WindowDragArea())
        .padding(.vertical, -3)
        .contentShape(Rectangle())
    }

    private var sourceLanguageMenu: some View {
        Menu {
            ForEach(Languages.sources) { language in
                Button {
                    settings.sourceLanguageID = language.id
                } label: {
                    if settings.sourceLanguageID == language.id {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 9))
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
        .disabled(model.phase == .loading)
        .help("原文语言：自动检测或手动指定")
    }

    private var targetLanguageMenu: some View {
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
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 9))
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
        .disabled(model.phase == .loading)
        .help("目标语言")
    }

    // MARK: - Input

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("原文", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.inputText.isEmpty {
                    Text("\(model.inputText.count) 字符")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.inputText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .focused($inputFocused)

                if model.inputText.isEmpty {
                    Text("输入或粘贴要翻译的文字…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Output

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("译文", systemImage: "character.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !model.endpointDescription.isEmpty {
                    Text(model.endpointDescription)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Button {
                    copyToPasteboard()
                } label: {
                    Label(
                        copied ? "已拷贝" : "拷贝",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .disabled(model.translatedText.isEmpty)
                .opacity(model.translatedText.isEmpty ? 0.35 : 1)
                .help("拷贝译文")
            }

            outputContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var outputContent: some View {
        switch model.phase {
        case .idle:
            emptyHint("翻译结果会显示在这里。")
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在翻译…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .success:
            ScrollView {
                Text(model.translatedText)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        case .failure:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.errorMessage ?? "翻译失败", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("重试", action: onTranslate)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("⌘↩ 翻译 · Esc 关闭")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("清空", action: onClear)
                .controlSize(.small)
                .disabled(!model.hasContent)

            Button(action: onTranslate) {
                HStack(spacing: 5) {
                    if model.phase == .loading {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.phase == .loading ? "翻译中…" : "翻译")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canTranslate)
        }
        .padding(.top, 10)
    }

    // MARK: - Helpers

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }

    private func copyToPasteboard() {
        let text = model.translatedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }

    private func retranslateIfNeeded() {
        guard model.phase == .success || model.phase == .failure else { return }
        guard !model.trimmedInput.isEmpty else { return }
        onTranslate()
    }
}

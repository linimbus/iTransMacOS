import SwiftUI

@MainActor
final class PopupModel: ObservableObject {
    enum Origin {
        case screenshot
        case selection
    }

    enum Phase {
        case prompt
        case loading
        case success
        case failure
    }

    let origin: Origin
    let originalText: String

    @Published var phase: Phase = .prompt
    @Published var translatedText: String = ""
    @Published var errorMessage: String?
    @Published var endpointDescription: String = ""
    @Published var copiedFlash: Bool = false

    private var flashWorkItem: DispatchWorkItem?

    init(originalText: String, origin: Origin) {
        self.originalText = originalText
        self.origin = origin
    }

    func flashCopied() {
        flashWorkItem?.cancel()
        copiedFlash = true
        let item = DispatchWorkItem { [weak self] in
            self?.copiedFlash = false
        }
        flashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }
}

@MainActor
struct PopupView: View {
    @ObservedObject var model: PopupModel
    @ObservedObject var settings: AppSettings
    var onTranslate: () -> Void
    var onRetry: () -> Void
    var onClose: () -> Void
    var onCopy: (String) -> Void
    var onOpenSettings: () -> Void
    var onTargetLanguageChanged: () -> Void

    private var title: String {
        model.origin == .screenshot ? "截图识别" : "划词翻译"
    }

    private var iconName: String {
        model.origin == .screenshot ? "viewfinder" : "text.cursor"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !model.originalText.isEmpty {
                originalBlock
            }

            switch model.phase {
            case .prompt:
                promptActions
            case .loading:
                loadingView
            case .success:
                successView
            case .failure:
                failureView
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .onChange(of: settings.targetLanguageID) { _, _ in
            onTargetLanguageChanged()
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)

            Spacer()

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

    private var originalBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: 3)

            Text(model.originalText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(model.phase == .prompt ? 5 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var promptActions: some View {
        HStack(spacing: 8) {
            Button(action: onTranslate) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                    Text("翻译")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)

            Button("复制原文") {
                onCopy(model.originalText)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在翻译…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 24)
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)

            HStack(spacing: 6) {
                Text("译文 · \(settings.targetLanguageName)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onCopy(model.translatedText)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.copiedFlash ? "checkmark" : "doc.on.doc")
                        Text(model.copiedFlash ? "已复制" : "复制译文")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Text(model.translatedText)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .lineLimit(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(model.endpointDescription)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("重新翻译", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Button("关闭", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text(model.errorMessage ?? "翻译失败")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("接口设置", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Button("关闭", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

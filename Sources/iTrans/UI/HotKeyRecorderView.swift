import AppKit
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.shortcut = shortcut
        view.onRecord = { recorded in
            context.coordinator.parent.shortcut = recorded
        }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        context.coordinator.parent = self
        nsView.shortcut = shortcut
    }

    final class Coordinator {
        var parent: HotKeyRecorderView
        init(_ parent: HotKeyRecorderView) {
            self.parent = parent
        }
    }
}

final class RecorderNSView: NSView {
    var shortcut: HotKeyShortcut = .ocrDefault {
        didSet { needsDisplay = true }
    }
    var onRecord: ((HotKeyShortcut) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            if isRecording {
                window?.makeFirstResponder(self)
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // ESC cancels recording
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }

        let recorded = HotKeyShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers.rawValue,
            isEnabled: true
        )
        shortcut = recorded
        onRecord?(recorded)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = isRecording ? "请按下快捷键…" : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        ))
    }
}

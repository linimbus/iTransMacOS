import AppKit

@MainActor
final class SelectedTextService {
    /// Reads the currently selected text. Tries the Accessibility API first and
    /// falls back to simulating ⌘C and reading the pasteboard.
    func readSelectedText() async -> String? {
        if let text = accessibilitySelectedText() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return await copySelectedText()
    }

    // MARK: - Accessibility

    private func accessibilitySelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return nil
        }

        var element = focusedValue as! AXUIElement
        for _ in 0..<6 {
            if let text = selectedText(of: element), !text.isEmpty {
                return text
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success, let parentValue else {
                break
            }
            element = parentValue as! AXUIElement
        }

        return nil
    }

    private func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: - Clipboard fallback

    private func copySelectedText() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        sendCopyKeystroke()

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let text = pasteboard.string(forType: .string), !text.isEmpty {
                snapshot.restore(to: pasteboard)
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        snapshot.restore(to: pasteboard)
        return nil
    }

    private func sendCopyKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true) // C
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        usleep(15_000)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var dictionary: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dictionary[type] = data
                }
            }
            return dictionary
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let newItems = items.map { dictionary -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dictionary {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(newItems)
    }
}

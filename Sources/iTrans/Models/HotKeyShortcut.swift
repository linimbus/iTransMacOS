import AppKit
import Carbon.HIToolbox

/// A globally registered keyboard shortcut.
struct HotKeyShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt
    var isEnabled: Bool

    init(keyCode: UInt16, modifiers: UInt, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var isValid: Bool {
        isEnabled && !modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    var carbonModifiers: UInt32 {
        let flags = modifierFlags
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    var displayString: String {
        guard isEnabled else { return "未设置" }
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += KeyCodeNames.name(for: keyCode)
        return result
    }

    static let ocrDefault = HotKeyShortcut(
        keyCode: 31, // O
        modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
    )

    static let selectionDefault = HotKeyShortcut(
        keyCode: 17, // T
        modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
    )

    static let audioDefault = HotKeyShortcut(
        keyCode: 37, // L
        modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
    )
}

enum KeyCodeNames {
    private static let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "Esc", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "PageUp", 117: "⌦", 118: "F4", 119: "End",
        120: "F2", 121: "PageDown", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑"
    ]

    static func name(for keyCode: UInt16) -> String {
        map[keyCode] ?? "Key\(keyCode)"
    }
}

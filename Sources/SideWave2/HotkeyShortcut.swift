// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Foundation

struct HotkeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags

    enum CodingKeys: String, CodingKey {
        case keyCode
        case modifierFlagsRawValue
    }

    /// Default: Right Option key
    static let defaultShortcut = HotkeyShortcut(keyCode: 61, modifierFlags: [])

    /// Whether this shortcut is a modifier-only key (no character key involved)
    var isModifierOnly: Bool {
        modifierFlags.isEmpty && Self.isModifierKeyCode(keyCode)
    }

    var displayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.command) { parts.append("⌘") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.function) { parts.append("fn") }

        if let key = Self.keyCodeToString(keyCode) {
            parts.append(key)
        } else {
            parts.append(String(Character(UnicodeScalar(keyCode) ?? "?")))
        }

        if modifierFlags.isEmpty {
            return parts.last ?? "Unknown"
        }

        return parts.joined(separator: " + ")
    }

    /// Compact symbol-only form for tight UI like the dictation overlay
    /// keycap. Modifier-only shortcuts collapse to their glyph (⌥ for
    /// right or left option, no L/R distinction since the gesture is
    /// unambiguous in context). Composite shortcuts join modifier glyphs
    /// with the key glyph using a thin space, matching macOS menu bar
    /// shortcut conventions.
    var compactDisplayString: String {
        var modifiers: [String] = []
        if modifierFlags.contains(.control) { modifiers.append("⌃") }
        if modifierFlags.contains(.option) { modifiers.append("⌥") }
        if modifierFlags.contains(.shift) { modifiers.append("⇧") }
        if modifierFlags.contains(.command) { modifiers.append("⌘") }
        if modifierFlags.contains(.function) { modifiers.append("fn") }

        let keyGlyph: String? = {
            if Self.isModifierKeyCode(keyCode) {
                switch keyCode {
                case 55, 54: return "⌘"
                case 58, 61: return "⌥"
                case 59, 62: return "⌃"
                case 56, 60: return "⇧"
                case 63: return "fn"
                default: return nil
                }
            }
            return Self.keyCodeToCompactGlyph(keyCode)
        }()

        if modifierFlags.isEmpty {
            return keyGlyph ?? Self.keyCodeToString(keyCode) ?? "?"
        }

        // Modifier + key; concatenate glyphs (no separator) so the keycap
        // reads like a stamped key.
        let key = keyGlyph ?? Self.keyCodeToString(keyCode) ?? "?"
        return modifiers.joined() + key
    }

    /// Single-glyph form of a non-modifier key for the compact overlay.
    /// Falls back to the longer label (or nil) for keys without a clean
    /// single glyph.
    private static func keyCodeToCompactGlyph(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "↩"      // Return
        case 48: return "⇥"      // Tab
        case 49: return "Space"
        case 51: return "⌫"      // Delete
        case 53: return "⎋"      // Escape
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return Self.keyCodeToString(keyCode)
        }
    }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 55, 54: return true // Left/Right Command
        case 58, 61: return true // Left/Right Option
        case 59, 62: return true // Left/Right Control
        case 56, 60: return true // Left/Right Shift
        case 63: return true     // fn
        default: return false
        }
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 55: return "Left ⌘"
        case 54: return "Right ⌘"
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        case 63: return "fn"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 24: return "="
        case 27: return "-"
        case 33: return "["
        case 30: return "]"
        case 41: return ";"
        case 39: return "'"
        case 42: return "\\"
        case 43: return ","
        case 47: return "."
        case 44: return "/"
        case 50: return "`"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        default: return nil
        }
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let raw = try container.decode(UInt.self, forKey: .modifierFlagsRawValue)
        modifierFlags = NSEvent.ModifierFlags(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifierFlags.rawValue, forKey: .modifierFlagsRawValue)
    }
}

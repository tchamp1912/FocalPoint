// FocalPoint menu-bar app — Carbon keycode <-> readable-string helpers.
// Shared by the hotkey recorder and the Hotkeys settings list so both render
// the exact same combo string (e.g. "⌃⌥2", "⌘⇧A").
// MIT License.

import AppKit
import Carbon

enum KeyCodeNames {
    /// kVK_ANSI_* / kVK_* -> display name. Covers letters, digits, the
    /// punctuation row, and the common named keys; anything missing falls
    /// back to "Key<code>" rather than crashing or showing nothing.
    private static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete",
        UInt32(kVK_Escape): "Escape",
        0x37: "Command", 0x38: "Shift", 0x39: "CapsLock", 0x3A: "Option",
        0x3B: "Control",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12",
        0x7B: "\u{2190}", 0x7C: "\u{2192}", 0x7D: "\u{2193}", 0x7E: "\u{2191}",
    ]

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key\(keyCode)"
    }

    /// Carbon modifier mask -> the standard macOS glyph order: ⌃⌥⇧⌘.
    static func modifierString(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "\u{2303}" }   // ⌃
        if modifiers & UInt32(optionKey) != 0 { s += "\u{2325}" }    // ⌥
        if modifiers & UInt32(shiftKey) != 0 { s += "\u{21E7}" }     // ⇧
        if modifiers & UInt32(cmdKey) != 0 { s += "\u{2318}" }       // ⌘
        return s
    }

    static func comboString(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierString(modifiers) + name(for: keyCode)
    }

    /// NSEvent.ModifierFlags (recorder input) -> Carbon modifier bits
    /// (persisted / RegisterEventHotKey input).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

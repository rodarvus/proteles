import Foundation

/// Parses a MUSHclient accelerator key string (`Accelerator`/`AcceleratorTo`,
/// e.g. `"Ctrl+P"`, `"Alt+F4"`, `"Ctrl+Shift+Numpad5"`) into a ``KeyChord`` for
/// the ``MacroEngine``. Pure + table-driven so it's unit-tested without UI.
///
/// Modifier names: `Ctrl`/`Control`, `Alt`/`Option`, `Shift`, `Cmd`/`Win`
/// (Windows plugins say `Win`; on the Mac that's ⌘). The final token is the key.
/// Returns `nil` for an unrecognised key, so a plugin's odd binding is ignored
/// rather than mis-bound.
public enum AcceleratorParser {
    public static func chord(from string: String) -> KeyChord? {
        let tokens = string.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let keyToken = tokens.last, !keyToken.isEmpty else { return nil }

        var modifiers: KeyModifiers = []
        for token in tokens.dropLast() {
            switch token {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command", "win", "windows", "super", "meta": modifiers.insert(.command)
            default: return nil // an unknown modifier — don't guess
            }
        }
        guard var chord = baseChord(for: keyToken) else { return nil }
        chord.modifiers = modifiers
        return chord
    }

    /// The key (no modifiers) as a ``KeyChord``, or nil if the name is unknown.
    private static func baseChord(for name: String) -> KeyChord? {
        if let code = letters[name] ?? digits[name] ?? specials[name] { return KeyChord(keyCode: code) }
        if let code = functionKeys[name] { return KeyChord(keyCode: code, isFunctionKey: true) }
        if let code = keypad[name] { return KeyChord(keyCode: code, isKeypad: true) }
        return nil
    }

    /// macOS virtual key codes (kVK_ANSI_*).
    private static let letters: [String: UInt16] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6
    ]
    private static let digits: [String: UInt16] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
    ]
    private static let specials: [String: UInt16] = [
        "space": 49, "tab": 48, "return": 36, "enter": 36, "escape": 53, "esc": 53,
        "backspace": 51, "delete": 51, "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119, "pageup": 116, "pgup": 116, "pagedown": 121, "pgdn": 121
    ]
    private static let functionKeys: [String: UInt16] = [
        "f1": KeyCode.f1, "f2": KeyCode.f2, "f3": KeyCode.f3, "f4": KeyCode.f4,
        "f5": KeyCode.f5, "f6": KeyCode.f6, "f7": KeyCode.f7, "f8": KeyCode.f8,
        "f9": KeyCode.f9, "f10": KeyCode.f10, "f11": KeyCode.f11, "f12": KeyCode.f12
    ]
    private static let keypad: [String: UInt16] = [
        "numpad0": KeyCode.keypad0, "numpad1": KeyCode.keypad1, "numpad2": KeyCode.keypad2,
        "numpad3": KeyCode.keypad3, "numpad4": KeyCode.keypad4, "numpad5": KeyCode.keypad5,
        "numpad6": KeyCode.keypad6, "numpad7": KeyCode.keypad7, "numpad8": KeyCode.keypad8,
        "numpad9": KeyCode.keypad9, "numpad+": KeyCode.keypadPlus, "numpad-": KeyCode.keypadMinus,
        "numpad*": KeyCode.keypadMultiply, "numpad/": KeyCode.keypadDivide,
        "numpad.": KeyCode.keypadDecimal, "numpadenter": KeyCode.keypadEnter
    ]
}

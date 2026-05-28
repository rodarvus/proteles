import MudCore
import SwiftUI

#if os(macOS)
    import AppKit

    /// Translate an AppKit keyDown into the platform-neutral ``KeyChord`` the
    /// ``MacroEngine`` matches on. Shared by the command field's key monitor and
    /// the macro editor's key recorder so both classify a chord identically.
    ///
    /// Keypad/function status comes from the key-code sets (not the `numericPad`
    /// flag, which macOS also sets for the arrow keys).
    func makeKeyChord(from event: NSEvent) -> KeyChord {
        let flags = event.modifierFlags
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let keyCode = event.keyCode
        return KeyChord(
            keyCode: keyCode,
            modifiers: modifiers,
            isKeypad: KeyCode.keypadSet.contains(keyCode),
            isFunctionKey: KeyCode.functionKeySet.contains(keyCode)
        )
    }

    /// A "record a key" control: shows the bound chord and, while recording,
    /// captures the next keypress into `chord`. The monitor is local to this
    /// app and swallows the captured key so it isn't typed anywhere.
    struct KeyChordRecorder: View {
        @Binding var chord: KeyChord
        @State private var recording = false
        @State private var monitor: Any?

        var body: some View {
            HStack {
                Text(KeyChordFormatter.describe(chord))
                    .font(.body.monospaced())
                    .foregroundStyle(chord.keyCode == 0 ? .secondary : .primary)
                Spacer()
                Button(recording ? "Press a key…" : "Record Key") {
                    recording ? stop() : start()
                }
                .buttonStyle(.bordered)
            }
            .onDisappear(perform: stop)
        }

        private func start() {
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                chord = makeKeyChord(from: event)
                stop()
                return nil
            }
        }

        private func stop() {
            recording = false
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }

#else

    /// Non-macOS placeholder: hardware-key capture isn't wired up off macOS yet.
    struct KeyChordRecorder: View {
        @Binding var chord: KeyChord

        var body: some View {
            HStack {
                Text(KeyChordFormatter.describe(chord)).font(.body.monospaced())
                Spacer()
                Text("Key capture requires macOS").foregroundStyle(.secondary)
            }
        }
    }

#endif

/// Renders a ``KeyChord`` as a readable label (e.g. `⌘⇧J`, `Keypad 8`, `F5`).
/// Pure — no AppKit — so it works for chords loaded from disk (which carry only
/// a key code) and on every platform.
enum KeyChordFormatter {
    static func describe(_ chord: KeyChord) -> String {
        guard chord.keyCode != 0 || !chord.modifiers.isEmpty else {
            return "No key set"
        }
        return modifierString(chord.modifiers) + keyName(chord)
    }

    private static func modifierString(_ modifiers: KeyModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    private static func keyName(_ chord: KeyChord) -> String {
        if chord.isKeypad, let name = keypadNames[chord.keyCode] {
            return "Keypad \(name)"
        }
        if chord.isFunctionKey, let name = functionNames[chord.keyCode] {
            return name
        }
        return mainKeyNames[chord.keyCode] ?? "Key \(chord.keyCode)"
    }

    private static let keypadNames: [UInt16: String] = [
        KeyCode.keypad0: "0", KeyCode.keypad1: "1", KeyCode.keypad2: "2",
        KeyCode.keypad3: "3", KeyCode.keypad4: "4", KeyCode.keypad5: "5",
        KeyCode.keypad6: "6", KeyCode.keypad7: "7", KeyCode.keypad8: "8",
        KeyCode.keypad9: "9", KeyCode.keypadDecimal: ".", KeyCode.keypadPlus: "+",
        KeyCode.keypadMinus: "−", KeyCode.keypadMultiply: "*", KeyCode.keypadDivide: "/",
        KeyCode.keypadEnter: "Enter", KeyCode.keypadEquals: "=", KeyCode.keypadClear: "Clear"
    ]

    private static let functionNames: [UInt16: String] = [
        KeyCode.f1: "F1", KeyCode.f2: "F2", KeyCode.f3: "F3", KeyCode.f4: "F4",
        KeyCode.f5: "F5", KeyCode.f6: "F6", KeyCode.f7: "F7", KeyCode.f8: "F8",
        KeyCode.f9: "F9", KeyCode.f10: "F10", KeyCode.f11: "F11", KeyCode.f12: "F12"
    ]

    /// ANSI US main-keyboard key codes → label (letters/digits + the keys a
    /// user is likely to bind). Display only; unmapped codes fall back to a
    /// numeric label.
    private static let mainKeyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

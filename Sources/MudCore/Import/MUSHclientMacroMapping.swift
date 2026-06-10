import Foundation

/// Maps MUSHclient macro slots into Proteles ``Macro``s. Pure.
///
/// MUSHclient has a fixed set of macro slots: `Alt+<letter>` and `F1`–`F12`
/// (each optionally `+Ctrl`/`+Shift`), plus *named* game-command slots
/// (`down`/`east`/`examine`/`look`/`say`/`who`/`quit`…) triggered from the Game
/// menu with no portable physical key. The keyed slots map to a ``KeyChord``;
/// the named slots import **unbound** (`KeyChord(keyCode: 0)` — Proteles'
/// "unassigned" sentinel: never fires, shown as "Record Key" in the editor) so
/// the user can bind them later. A named slot that merely *looks* like a key
/// (e.g. `down`) is still left unbound — it is not the arrow key.
public enum MUSHclientMacroMapping {
    private static let modifierTokens: Set<String> =
        ["alt", "option", "opt", "ctrl", "control", "shift", "cmd", "command", "win", "windows"]

    /// The Proteles key chord for a MUSHclient slot name, or nil when the slot is
    /// a named game-command (→ import unbound). Order-agnostic about modifier vs
    /// key position (MUSHclient writes `Alt+A` but `F10+Ctrl`).
    public static func keyChord(forSlot name: String) -> KeyChord? {
        let parts = name.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let keys = parts.filter { !modifierTokens.contains($0) }
        let mods = parts.filter(modifierTokens.contains)
        guard keys.count == 1, let keyToken = keys.first, isKeyToken(keyToken) else { return nil }
        // Reconstruct in modifier+key order for AcceleratorParser.
        return AcceleratorParser.chord(from: (mods + [keyToken]).joined(separator: "+"))
    }

    /// A keyed slot's token is a single letter `a`–`z` or a function key `f1`–`f12`.
    private static func isKeyToken(_ token: String) -> Bool {
        if token.count == 1, token >= "a", token <= "z" { return true }
        if token.first == "f", let number = Int(token.dropFirst()), (1...12).contains(number) { return true }
        return false
    }

    /// Map the world's macros to Proteles macros, dropping:
    /// - empty commands; and
    /// - **identity** named slots, whose command (trimmed) equals the slot
    ///   name (`north` → `north`, `examine` → `examine`, `drop` → `drop `) —
    ///   MUSHclient's default Game-menu slots, *whatever their type*. They're
    ///   compatibility artifacts for antique MUDs, never user intent, and an
    ///   Aardwolf player has no use for an unbound "examine → examine" macro
    ///   (live-import feedback, 2026-06-10; previously only the send-now ones
    ///   were dropped and the `replace`-type defaults slipped through). Keyed
    ///   slots (F-keys / Alt+letter) are never dropped by this rule: their
    ///   name is a key label, so it never equals the command.
    public static func macros(from slots: [MUSHclientWorldFile.Macro]) -> [Macro] {
        slots.compactMap { slot in
            let command = slot.send.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            let name = slot.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let chord = keyChord(forSlot: slot.name)
            // Identity check on the *unkeyed* (Game-menu) slots only.
            guard chord != nil || name.lowercased() != command.lowercased() else { return nil }
            // `replace` macros prefill the command line for the user to finish
            // (e.g. `say `); `send_now` (+ anything else) sends immediately.
            // Preserve a prefill's trailing space (the separator before the user's
            // text); only strip XML newlines. A send-now command is fully trimmed.
            let action: MacroAction = slot.type == "replace"
                ? .replaceInput(slot.send.trimmingCharacters(in: .newlines))
                : .command(command)
            return Macro(name: slot.name, chord: chord ?? KeyChord(keyCode: 0), action: action)
        }
    }
}

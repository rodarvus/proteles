import MudCore

/// Resolves one keypress from the command field's key monitor through the
/// binding layers, in precedence order (D-102): an explicit **macro** wins,
/// then the **keypad** grid, then a command-button **hotkey** (#40) as the
/// fallback for the same chord. The winner fires; the outcome tells the
/// monitor whether to swallow the key.
///
/// Every keypad/function-key chord also leaves a `NOTE` in the session
/// transcript naming the layer that took it (or `unhandled`, with the raw
/// key code) — so a live "this key did nothing" report is diagnosable from
/// a recording instead of unreproducible (the D-31 discipline; added while
/// chasing a keypad-`=` no-op on an external keypad, 2026-06-10).
@MainActor
public enum MacroKeyDispatch {
    public static func handle(
        _ chord: KeyChord,
        context: MacroContext,
        scripts: ScriptsModel,
        session: SessionController
    ) -> MacroKeyOutcome {
        let outcome: MacroKeyOutcome
        let layer: String
        if let action = scripts.matchMacro(chord, context: context) {
            layer = "macro"
            if case .replaceInput(let text) = action {
                outcome = .replaceInput(text)
            } else {
                Task { await session.fire(action) }
                outcome = .handled
            }
        } else if let action = scripts.matchKeypad(chord) {
            layer = "keypad"
            Task { await session.fire(action) }
            outcome = .handled
        } else if let buttonID = scripts.matchButtonHotkey(chord, context: context) {
            layer = "button hotkey"
            Task { await scripts.fireButton(buttonID) }
            outcome = .handled
        } else {
            layer = "unhandled"
            outcome = .notHandled
        }
        if chord.isKeypad || chord.isFunctionKey {
            let note = "key: \(KeyChordFormatter.describe(chord)) "
                + "(code=\(chord.keyCode) mods=\(chord.modifiers.rawValue)) → \(layer)"
            Task { await session.recordNote(note) }
        }
        return outcome
    }
}

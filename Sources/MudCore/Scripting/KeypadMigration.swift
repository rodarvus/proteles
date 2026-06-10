import Foundation

/// One-time migration for D-102: the keypad became a first-class layer, so
/// the D-50 *macros* that used to provide keypad navigation move into the
/// ``Keypad`` model. Pure and idempotent — once the untouched defaults are
/// gone from the macro set, `migrate` returns nil forever.
///
/// Two cases, keyed on whether the profile already has keypad bindings
/// (e.g. from a MUSHclient import, which wrote the keypad store before
/// anything read it):
/// - **Keypad empty:** the untouched default macros *move* — they become
///   keypad bindings and leave the macro set.
/// - **Keypad populated:** the untouched default macros are *removed* so
///   they stop shadowing the imported bindings (macros win at runtime).
///
/// "Untouched" is exact: every field the editor can change must still match
/// the shipped default (a renamed, re-bound, re-labelled, or *disabled*
/// macro is the user's, and stays a macro).
public enum KeypadMigration {
    /// The migrated (macros, keypad) pair, or nil when there is nothing to
    /// do (no untouched D-50 defaults left in `macros`).
    public static func migrate(
        macros: [Macro],
        keypad: Keypad
    ) -> (macros: [Macro], keypad: Keypad)? {
        let defaults = MacroEngine.defaultNavigationMacros()
        func isUntouchedDefault(_ macro: Macro) -> Bool {
            macro.enabled && defaults.contains {
                $0.chord == macro.chord && $0.action == macro.action
                    && $0.name == macro.name && $0.label == macro.label
            }
        }
        let untouched = macros.filter(isUntouchedDefault)
        guard !untouched.isEmpty else { return nil }

        var migrated = keypad
        if keypad.bindings.isEmpty {
            migrated.bindings = untouched.compactMap { macro in
                guard let key = KeypadKey(keyCode: macro.chord.keyCode),
                      case .command(let command) = macro.action
                else { return nil }
                return KeypadBinding(key: key, command: command)
            }
        }
        return (macros.filter { !isUntouchedDefault($0) }, migrated)
    }
}

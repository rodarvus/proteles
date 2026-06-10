import Foundation
import MudCore

/// The keypad command grid (D-102): mutations from the Keypad tab, the
/// runtime match the key monitor calls, and the one-time D-50 migration +
/// fresh-profile seeding run on every world load.
public extension ScriptsModel {
    /// The action a keypad keypress should fire, or nil. Sits *behind*
    /// ``matchMacro(_:context:)`` in the key monitor's precedence — a macro
    /// on a keypad key is an explicit override — and *ahead of* button
    /// hotkeys. Synchronous (main-actor) so the monitor can decide inline.
    func matchKeypad(_ chord: KeyChord) -> MacroAction? {
        keypad.action(for: chord)
    }

    /// Master on/off for keypad sending (the editor's toggle).
    func setKeypadEnabled(_ enabled: Bool) async {
        var updated = keypad
        updated.enabled = enabled
        await applyKeypad(updated)
    }

    /// Bind `key` to `command` (replacing any existing binding); an empty
    /// command unbinds the key.
    func setKeypadCommand(_ command: String, for key: KeypadKey) async {
        var updated = keypad
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = updated.bindings.firstIndex(where: { $0.key == key }) {
            if trimmed.isEmpty {
                updated.bindings.remove(at: index)
            } else {
                updated.bindings[index].command = trimmed
            }
        } else if !trimmed.isEmpty {
            updated.bindings.append(KeypadBinding(key: key, command: trimmed))
        }
        await applyKeypad(updated)
    }

    /// Replace the grid with the built-in navigation layout (the editor's
    /// confirmed "Restore Defaults" action).
    func restoreDefaultKeypad() async {
        await applyKeypad(.defaultNavigation)
    }

    internal func applyKeypad(_ updated: Keypad) async {
        try? await store?.setKeypad(updated)
        await refresh()
    }

    /// On every load: run the one-time D-50→keypad migration (idempotent —
    /// see ``KeypadMigration``), then seed the default layout on a genuinely
    /// fresh profile. A pre-keypad profile (its macros were seeded under the
    /// old `macrosSeeded` flag) is *not* re-seeded: the migration owns its
    /// keypad, and an empty grid there is the user's own deletion.
    internal func migrateAndSeedKeypad(store: ScriptStore, profileID: UUID) async {
        let document = await store.document
        if let (macros, keypad) = KeypadMigration.migrate(
            macros: document.macros, keypad: document.keypad
        ) {
            var migrated = document
            migrated.macros = macros
            migrated.keypad = keypad
            try? await store.replace(with: migrated)
        }

        let seededKey = "com.proteles.keypadSeeded.\(profileID.uuidString)"
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        let preKeypadProfile = UserDefaults.standard
            .bool(forKey: "com.proteles.macrosSeeded.\(profileID.uuidString)")
        let current = await store.document.keypad
        if current.bindings.isEmpty, !preKeypadProfile {
            try? await store.setKeypad(.defaultNavigation)
        }
    }
}

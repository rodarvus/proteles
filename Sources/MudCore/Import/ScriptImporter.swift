import Foundation

/// Write phase (P2): apply imported macros + keypad to a character's
/// ``ScriptStore``. Macros are **appended** to any existing ones (so a merge
/// keeps the user's current macros); the keypad replaces the grid. Existing
/// triggers/aliases/timers/button-bar are preserved (read, then written back).
public enum ScriptImporter {
    public static func apply(
        macros: [Macro],
        keypad: Keypad,
        into store: ScriptStore
    ) async throws {
        var document = await store.document
        document.macros.append(contentsOf: macros)
        document.keypad = keypad
        try await store.replace(with: document)
    }
}

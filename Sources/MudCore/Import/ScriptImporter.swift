import Foundation

/// Write phase (P2): apply imported scripts to a character's ``ScriptStore``.
/// Macros, aliases, and triggers are **appended** to any existing ones (so a
/// merge keeps the user's current scripts); the keypad replaces the grid.
/// Existing timers/button-bar are preserved (read, then written back).
public enum ScriptImporter {
    public static func apply(
        macros: [Macro],
        keypad: Keypad,
        aliases: [Alias] = [],
        triggers: [Trigger] = [],
        timers: [MudTimer] = [],
        into store: ScriptStore
    ) async throws {
        var document = await store.document
        document.macros.append(contentsOf: macros)
        document.aliases.append(contentsOf: aliases)
        document.triggers.append(contentsOf: triggers)
        document.timers.append(contentsOf: timers)
        document.keypad = keypad
        try await store.replace(with: document)
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("ScriptImporter — write macros + keypad to a character store")
struct ScriptImporterTests {
    private func store() -> ScriptStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scripts-\(UUID().uuidString)", isDirectory: true)
        return ScriptStore(directory: dir, character: "Hero")
    }

    @Test("appends macros, sets keypad, preserves existing scripts; persists across reload")
    func apply() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scripts-\(UUID().uuidString)", isDirectory: true)
        let store = ScriptStore(directory: dir, character: "Hero")
        try await store.load()
        // Pre-existing macro + a trigger that must survive the import.
        try await store.replace(with: ScriptDocument(
            triggers: [Trigger(pattern: .substring("x"))],
            macros: [Macro(chord: KeyChord(keyCode: 1), action: .command("old"))]
        ))

        let imported = [Macro(chord: KeyChord(keyCode: 0), action: .command("north"))]
        let keypad = Keypad(bindings: [.init(key: .num8, command: "north")])
        try await ScriptImporter.apply(macros: imported, keypad: keypad, into: store)

        #expect(await store.macros.count == 2) // old + imported
        #expect(await store.triggers.count == 1) // preserved
        #expect(await store.keypad.command(for: .num8) == "north")

        // Reload from disk → keypad persisted.
        let reloaded = ScriptStore(directory: dir, character: "Hero")
        try await reloaded.load()
        #expect(await reloaded.keypad.command(for: .num8) == "north")
        #expect(await reloaded.macros.count == 2)
    }
}

import Foundation
import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("Scripts window keypad model (D-102)")
struct KeypadModelTests {
    private static func makeModel() async throws -> (ScriptsModel, ScriptStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-keypad-tests-\(UUID().uuidString)")
        let store = ScriptStore(directory: directory, character: "test")
        try await store.load()
        let model = ScriptsModel(session: SessionController())
        model.store = store
        await model.refresh()
        return (model, store)
    }

    @Test("set, replace, and unbind a key — mirrored and persisted")
    func setReplaceUnbind() async throws {
        let (model, store) = try await Self.makeModel()

        await model.setKeypadCommand("xcp 1", for: .num7)
        #expect(model.keypad.command(for: .num7) == "xcp 1")

        await model.setKeypadCommand("xcp 2", for: .num7)
        #expect(model.keypad.command(for: .num7) == "xcp 2")
        #expect(model.keypad.bindings.count == 1)

        // Whitespace-only unbinds, same as empty.
        await model.setKeypadCommand("  ", for: .num7)
        #expect(model.keypad.command(for: .num7) == nil)
        let persisted = await store.document.keypad
        #expect(persisted.bindings.isEmpty)
    }

    @Test("the enable toggle persists and gates matching")
    func enableToggle() async throws {
        let (model, _) = try await Self.makeModel()
        await model.setKeypadCommand("north", for: .num8)
        let chord = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        #expect(model.matchKeypad(chord) == .command("north"))

        await model.setKeypadEnabled(false)
        #expect(model.matchKeypad(chord) == nil)

        await model.setKeypadEnabled(true)
        #expect(model.matchKeypad(chord) == .command("north"))
    }

    @Test("restore defaults replaces the grid with the navigation set")
    func restoreDefaults() async throws {
        let (model, _) = try await Self.makeModel()
        await model.setKeypadCommand("something", for: .num8)
        await model.restoreDefaultKeypad()
        // Compare by content — KeypadBinding ids are fresh per construction.
        #expect(model.keypad.enabled)
        #expect(model.keypad.bindings.count == 11)
        #expect(model.keypad.command(for: .num8) == "north")
        #expect(model.keypad.command(for: .multiply) == "eq")
    }

    @Test("load-time migration: D-50 macros move into an empty keypad once")
    func loadTimeMigration() async throws {
        let (model, store) = try await Self.makeModel()
        var document = await store.document
        document.macros = MacroEngine.defaultNavigationMacros()
        try await store.replace(with: document)

        await model.migrateAndSeedKeypad(store: store, profileID: UUID())
        await model.refresh()

        #expect(model.macros.isEmpty)
        #expect(model.keypad.command(for: .num8) == "north")
        #expect(model.keypad.bindings.count == 11)
    }

    @Test("dispatch: macro outranks keypad on the same key; unbound keys pass through")
    func dispatchPrecedence() async throws {
        let (model, store) = try await Self.makeModel()
        await model.setKeypadCommand("north", for: .num8)
        let chord = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        let session = SessionController()

        // Keypad layer takes the bound key…
        #expect(MacroKeyDispatch.handle(
            chord, context: MacroContext(), scripts: model, session: session
        ) == .handled)
        // …an unbound keypad key passes through to typing…
        #expect(MacroKeyDispatch.handle(
            KeyChord(keyCode: KeyCode.keypad9, isKeypad: true),
            context: MacroContext(),
            scripts: model,
            session: session
        ) == .notHandled)

        // …and a macro on the same key wins (observable: replace-input is a
        // macro-only outcome, so .replaceInput proves the macro fired).
        try await store.addMacro(Macro(chord: chord, action: .replaceInput("say ")))
        await model.refresh()
        #expect(MacroKeyDispatch.handle(
            chord, context: MacroContext(), scripts: model, session: session
        ) == .replaceInput("say "))
    }

    @Test("a genuinely fresh profile is seeded with the default layout, once")
    func freshSeed() async throws {
        let (model, store) = try await Self.makeModel()
        let profileID = UUID()

        await model.migrateAndSeedKeypad(store: store, profileID: profileID)
        await model.refresh()
        #expect(model.keypad.bindings.count == 11)
        #expect(model.keypad.command(for: .num8) == "north")

        // The user clears the grid; a later load must not re-seed it.
        await model.setKeypadCommand("", for: .num8)
        await model.migrateAndSeedKeypad(store: store, profileID: profileID)
        await model.refresh()
        #expect(model.keypad.command(for: .num8) == nil)
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("ScriptStore — split, scoped persistence", .serialized)
struct ScriptStoreTests {
    private func temporaryDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-scripts-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A fresh directory loads as empty sets and writes nothing")
    func missingFilesAreEmpty() async throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ScriptStore(directory: dir, character: "rodarvus")
        try await store.load()

        #expect(await store.triggers.isEmpty)
        #expect(await store.aliases.isEmpty)
        #expect(await store.timers.isEmpty)
        #expect(await store.macros.isEmpty)
        // No per-kind file created until the first edit.
        #expect(!FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("rodarvus/triggers.json").path))
    }

    @Test("Added automations round-trip through their split files")
    func roundTrips() async throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let trigger = Trigger(pattern: .wildcard("* arrives"), sendText: "kill %1")
        let alias = Alias(pattern: .wildcard("gg *"), sendText: "get %1 corpse")
        let timer = MudTimer(schedule: .every(10), action: .send("save"))

        do {
            let store = ScriptStore(directory: dir, character: "rodarvus")
            try await store.load()
            try await store.addTrigger(trigger)
            try await store.addAlias(alias)
            try await store.addTimer(timer)
        }
        // Each kind has its own discoverable file under the character dir.
        #expect(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("rodarvus/triggers.json").path))
        #expect(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("rodarvus/aliases.json").path))

        let reopened = ScriptStore(directory: dir, character: "rodarvus")
        try await reopened.load()
        #expect(await reopened.triggers == [trigger])
        #expect(await reopened.aliases == [alias])
        #expect(await reopened.timers == [timer])
    }

    @Test("Every TriggerPattern and TimerSchedule case survives a round-trip")
    func encodesAllCases() async throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let triggers = [
            Trigger(pattern: .substring("foo")),
            Trigger(pattern: .beginsWith("bar")),
            Trigger(pattern: .exact("baz")),
            Trigger(pattern: .wildcard("a * b")),
            Trigger(pattern: .regex(#"^\d+$"#))
        ]
        let aliases: [Alias] = [.world, .execute, .script, .output].map {
            Alias(pattern: .exact("x"), sendText: "y", sendTo: $0)
        }
        let timers = [
            MudTimer(schedule: .after(5), action: .send("a")),
            MudTimer(schedule: .every(10, offset: 2), action: .script("b")),
            MudTimer(schedule: .atTimeOfDay(hour: 6, minute: 30, second: 1.5), action: .send("c"))
        ]

        let store = ScriptStore(directory: dir, character: "c")
        try await store.load()
        try await store.replace(with: ScriptDocument(triggers: triggers, aliases: aliases, timers: timers))

        let reopened = ScriptStore(directory: dir, character: "c")
        try await reopened.load()
        #expect(await reopened.triggers == triggers)
        #expect(await reopened.aliases == aliases)
        #expect(await reopened.timers == timers)
    }

    @Test("Update replaces by id; remove drops by id; unknown id throws")
    func updateRemoveAndUnknown() async throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var trigger = Trigger(pattern: .substring("a"), sendText: "one")
        let store = ScriptStore(directory: dir, character: "c")
        try await store.load()
        try await store.addTrigger(trigger)
        trigger.sendText = "two"
        try await store.updateTrigger(trigger)
        #expect(await store.triggers.first?.sendText == "two")
        try await store.removeTrigger(id: trigger.id)
        #expect(await store.triggers.isEmpty)

        await #expect(throws: ScriptStore.StoreError.self) {
            try await store.updateAlias(Alias(pattern: .exact("nope")))
        }
        await #expect(throws: ScriptStore.StoreError.self) {
            try await store.removeTimer(id: UUID())
        }
    }

    @Test("Macros round-trip and update/remove by id")
    func macrosRoundTrip() async throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var macro = Macro(
            name: "North",
            chord: KeyChord(keyCode: KeyCode.keypad8, isKeypad: true),
            action: .command("n")
        )
        let store = ScriptStore(directory: dir, character: "c")
        try await store.load()
        try await store.addMacro(macro)

        let reopened = ScriptStore(directory: dir, character: "c")
        try await reopened.load()
        #expect(await reopened.macros == [macro])

        macro.action = .command("north")
        try await store.updateMacro(macro)
        #expect(await store.macros.first?.action == .command("north"))
        try await store.removeMacro(id: macro.id)
        #expect(await store.macros.isEmpty)
    }

    @Test("A kind toggled global is shared across characters; per-character kinds aren't")
    func globalScopeSharesAcrossCharacters() async throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let shared = Trigger(pattern: .substring("global"), sendText: "g")
        let mine = Alias(pattern: .exact("mine"), sendText: "m")

        // Character "alpha": add a trigger, make triggers global; add a per-char alias.
        let alpha = ScriptStore(directory: dir, character: "alpha")
        try await alpha.load()
        try await alpha.addTrigger(shared)
        try await alpha.setGlobal(.triggers, true) // moves triggers → _shared
        try await alpha.addAlias(mine)
        #expect(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("_shared/triggers.json").path))

        // Character "beta" (fresh) sees the global triggers but not alpha's alias.
        let beta = ScriptStore(directory: dir, character: "beta")
        try await beta.load()
        #expect(await beta.scope.triggers) // scope.json is read back
        #expect(await beta.triggers == [shared])
        #expect(await beta.aliases.isEmpty)
    }

    @Test("ScriptEngine.reload replaces the whole automation set")
    func engineReloadReplaces() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("old"), sendText: "x"))
        #expect(await engine.triggerList.count == 1)

        await engine.reload(ScriptDocument(triggers: [
            Trigger(pattern: .substring("new1")),
            Trigger(pattern: .substring("new2"))
        ]))
        #expect(await engine.triggerList.map(\.pattern) == [.substring("new1"), .substring("new2")])
    }

    @Test("ScriptEngine.load ingests a document and skips invalid entries")
    func engineLoadSkipsInvalid() async throws {
        let document = ScriptDocument(
            triggers: [
                Trigger(pattern: .wildcard("good *"), sendText: "ok"),
                Trigger(pattern: .regex("(unclosed"), sendText: "bad")
            ],
            aliases: [Alias(pattern: .exact("hi"), sendText: "wave")],
            timers: [MudTimer(schedule: .every(5), action: .send("tick"))]
        )
        let engine = try ScriptEngine()
        await engine.load(document)
        #expect(await engine.triggerList.count == 1)
        #expect(await engine.aliasList.count == 1)
        #expect(await engine.timerList.count == 1)
    }
}

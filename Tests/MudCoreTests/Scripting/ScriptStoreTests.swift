import Foundation
@testable import MudCore
import Testing

@Suite("ScriptStore — persistence", .serialized)
struct ScriptStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "proteles-scripts-test-\(UUID().uuidString).json"
        )
    }

    @Test("A missing file loads as an empty set and writes nothing")
    func missingFileIsEmpty() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScriptStore(url: url)
        try await store.load()

        #expect(await store.triggers.isEmpty)
        #expect(await store.aliases.isEmpty)
        #expect(await store.timers.isEmpty)
        // No file created until the first edit.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Added automations round-trip through disk")
    func roundTrips() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let trigger = Trigger(pattern: .wildcard("* arrives"), sendText: "kill %1")
        let alias = Alias(pattern: .wildcard("gg *"), sendText: "get %1 corpse")
        let timer = MudTimer(schedule: .every(10), action: .send("save"))

        do {
            let store = ScriptStore(url: url)
            try await store.load()
            try await store.addTrigger(trigger)
            try await store.addAlias(alias)
            try await store.addTimer(timer)
        }

        let reopened = ScriptStore(url: url)
        try await reopened.load()
        #expect(await reopened.triggers == [trigger])
        #expect(await reopened.aliases == [alias])
        #expect(await reopened.timers == [timer])
    }

    @Test("Every TriggerPattern and TimerSchedule case survives a round-trip")
    func encodesAllCases() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

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

        let store = ScriptStore(url: url)
        try await store.load()
        try await store.replace(with: ScriptDocument(
            triggers: triggers, aliases: aliases, timers: timers
        ))

        let reopened = ScriptStore(url: url)
        try await reopened.load()
        #expect(await reopened.triggers == triggers)
        #expect(await reopened.aliases == aliases)
        #expect(await reopened.timers == timers)
    }

    @Test("Update replaces by id; remove drops by id")
    func updateAndRemove() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var trigger = Trigger(pattern: .substring("a"), sendText: "one")
        let store = ScriptStore(url: url)
        try await store.load()
        try await store.addTrigger(trigger)

        trigger.sendText = "two"
        try await store.updateTrigger(trigger)
        #expect(await store.triggers.first?.sendText == "two")

        try await store.removeTrigger(id: trigger.id)
        #expect(await store.triggers.isEmpty)
    }

    @Test("Updating or removing an unknown id throws notFound")
    func unknownIDThrows() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScriptStore(url: url)
        try await store.load()
        let ghost = Alias(pattern: .exact("nope"))
        await #expect(throws: ScriptStore.StoreError.self) {
            try await store.updateAlias(ghost)
        }
        await #expect(throws: ScriptStore.StoreError.self) {
            try await store.removeTimer(id: UUID())
        }
    }

    @Test("ScriptEngine.reload replaces the whole automation set")
    func engineReloadReplaces() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("old"), sendText: "x"))
        #expect(await engine.triggerList.count == 1)

        await engine.reload(ScriptDocument(
            triggers: [
                Trigger(pattern: .substring("new1")),
                Trigger(pattern: .substring("new2"))
            ]
        ))
        let patterns = await engine.triggerList.map(\.pattern)
        #expect(patterns == [.substring("new1"), .substring("new2")])
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

        // The malformed regex trigger was skipped; the valid one survives.
        #expect(await engine.triggerList.count == 1)
        #expect(await engine.aliasList.count == 1)
        #expect(await engine.timerList.count == 1)
    }
}

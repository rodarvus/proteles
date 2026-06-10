import Foundation
import MudCore
@testable import MudUI
import Testing

@Suite("Scripts window filter (#35)")
struct ScriptItemFilterTests {
    private let trigger = Trigger(
        name: "hunt-next",
        pattern: .regex(#"^You are hunting (\w+)\.$"#),
        group: "hunt",
        sendText: "kill %1",
        script: "Note('engaged')"
    )

    @Test("an empty or all-whitespace query matches everything")
    func emptyQueryMatchesAll() {
        #expect(ScriptItemFilter.matches(trigger, query: ""))
        #expect(ScriptItemFilter.matches(trigger, query: "   "))
    }

    @Test("triggers match on pattern, send text, script, name, and group — case-insensitively")
    func triggerFields() {
        #expect(ScriptItemFilter.matches(trigger, query: "HUNTING")) // pattern
        #expect(ScriptItemFilter.matches(trigger, query: "kill %1")) // send text
        #expect(ScriptItemFilter.matches(trigger, query: "engaged")) // script
        #expect(ScriptItemFilter.matches(trigger, query: "hunt-next")) // name
        #expect(ScriptItemFilter.matches(trigger, query: "hunt")) // group
        #expect(!ScriptItemFilter.matches(trigger, query: "teleport"))
    }

    @Test("a query is trimmed before matching")
    func queryTrimming() {
        #expect(ScriptItemFilter.matches(trigger, query: "  hunting  "))
    }

    @Test("aliases match on pattern, expansion, name, and group")
    func aliasFields() {
        let alias = Alias(
            name: "quick-kill",
            pattern: .wildcard("k *"),
            group: "combat",
            sendText: "kill %1"
        )
        #expect(ScriptItemFilter.matches(alias, query: "k *"))
        #expect(ScriptItemFilter.matches(alias, query: "KILL"))
        #expect(ScriptItemFilter.matches(alias, query: "quick"))
        #expect(ScriptItemFilter.matches(alias, query: "combat"))
        #expect(!ScriptItemFilter.matches(alias, query: "flee"))
    }

    @Test("timers match on label, group, and either action's text")
    func timerFields() {
        let sender = MudTimer(
            label: "keepalive",
            group: "idle",
            schedule: .every(60),
            action: .send("look")
        )
        let scripted = MudTimer(schedule: .every(30), action: .script("CheckQuest()"))
        #expect(ScriptItemFilter.matches(sender, query: "keepalive"))
        #expect(ScriptItemFilter.matches(sender, query: "idle"))
        #expect(ScriptItemFilter.matches(sender, query: "look"))
        #expect(ScriptItemFilter.matches(scripted, query: "checkquest"))
        #expect(!ScriptItemFilter.matches(sender, query: "quest"))
    }

    @Test("macros match on name, label, action text, and the key description")
    func macroFields() {
        let macro = Macro(
            name: "north-fast",
            chord: KeyChord(keyCode: 126), // ↑ arrow
            action: .command("run n"),
            label: "N!"
        )
        #expect(ScriptItemFilter.matches(macro, query: "north-fast"))
        #expect(ScriptItemFilter.matches(macro, query: "N!"))
        #expect(ScriptItemFilter.matches(macro, query: "run n"))
        let described = KeyChordFormatter.describe(macro.chord)
        #expect(ScriptItemFilter.matches(macro, query: described))
        #expect(!ScriptItemFilter.matches(macro, query: "south"))
    }

    @Test("replace-input macros match on their replacement text")
    func macroReplaceInput() {
        let macro = Macro(chord: KeyChord(keyCode: 1), action: .replaceInput("say "))
        #expect(ScriptItemFilter.matches(macro, query: "say"))
    }
}

@MainActor
@Suite("Scripts window group bulk enable/disable (#35)")
struct ScriptGroupBulkTests {
    /// A model wired to a real (temp-dir) store and a session with no engine
    /// attached — exactly the store-side path the live app uses.
    private static func makeModel() async throws -> (ScriptsModel, ScriptStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-group-tests-\(UUID().uuidString)")
        let store = ScriptStore(directory: directory, character: "test")
        try await store.load()
        let model = ScriptsModel(session: SessionController())
        model.store = store
        return (model, store)
    }

    @Test("disabling a trigger group flips exactly its members, and persists")
    func triggerGroupDisable() async throws {
        let (model, store) = try await Self.makeModel()
        let hunted = Trigger(pattern: .substring("a"), group: "hunt")
        let hunted2 = Trigger(pattern: .substring("b"), group: "hunt")
        let other = Trigger(pattern: .substring("c"), group: "loot")
        let loner = Trigger(pattern: .substring("d"))
        for trigger in [hunted, hunted2, other, loner] {
            try await store.addTrigger(trigger)
        }
        await model.refresh()

        await model.setTriggerGroupEnabled("hunt", false)

        let byID = Dictionary(uniqueKeysWithValues: model.triggers.map { ($0.id, $0) })
        #expect(byID[hunted.id]?.enabled == false)
        #expect(byID[hunted2.id]?.enabled == false)
        #expect(byID[other.id]?.enabled == true)
        #expect(byID[loner.id]?.enabled == true)
        // And the store (persistence) agrees, not just the mirror:
        let stored = await store.document.triggers
        #expect(stored.filter { $0.group == "hunt" }.allSatisfy { !$0.enabled })

        await model.setTriggerGroupEnabled("hunt", true)
        let allEnabled = model.triggers.allSatisfy(\.enabled)
        #expect(allEnabled)
    }

    @Test("alias and timer groups toggle through the same path")
    func aliasAndTimerGroups() async throws {
        let (model, _) = try await Self.makeModel()
        let alias = Alias(pattern: .exact("aa"), group: "g")
        let timer = MudTimer(group: "g", schedule: .every(5), action: .send("x"))
        try await model.store?.addAlias(alias)
        try await model.store?.addTimer(timer)
        await model.refresh()

        await model.setAliasGroupEnabled("g", false)
        await model.setTimerGroupEnabled("g", false)
        #expect(model.aliases.first?.enabled == false)
        #expect(model.timers.first?.enabled == false)
    }
}

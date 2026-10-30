import Foundation
@testable import MudCore
import Testing

/// The actionable-state seams in the engine (S0b item 1, #84): ingest ahead
/// of every guard, observe without changing the line, publish only on change.
@Suite("ActionableState — engine seams", .serialized)
struct ActionableStateEngineTests {
    /// Answers every state change with a marker echo, so a test can see
    /// whether the hook ran.
    private struct Spy: NativePlugin {
        let metadata = NativePluginMetadata(
            id: "test.state-spy",
            name: "Spy",
            author: "t",
            version: "1",
            summary: ""
        )
        mutating func onStateChange(
            _: ActionableState,
            changed _: Set<ActionableState.Entity>
        ) -> [ScriptEffect] {
            [.echo("state changed")]
        }
    }

    private func states(_ effects: [ScriptEffect]) -> [ActionableState] {
        effects.compactMap { if case .updateState(let state) = $0 { state } else { nil } }
    }

    private func others(_ effects: [ScriptEffect]) -> [ScriptEffect] {
        effects.filter { if case .updateState = $0 { false } else { true } }
    }

    @Test("a line inside a block still reaches triggers and display unchanged")
    func observesOnly() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("crossbill"), sendText: "seen"))
        _ = await engine.process(line: "{roomchars}")
        let inside = await engine.process(line: "(R) The seething crossbill flies through the sky.")
        #expect(!inside.gag && inside.replacement == nil)
        #expect(others(inside.effects).count == 1, "the trigger's send, and nothing else")
        #expect(states(inside.effects).isEmpty)
    }

    @Test("a block is tracked while scripts are suspended")
    func trackedWhileSuspended() async throws {
        let engine = try ScriptEngine()
        await engine.setSuspended(true)
        _ = await engine.process(line: "{roomchars}")
        let closing = await engine.process(line: "{/roomchars}")
        #expect(states(closing.effects).first?.status(of: .roomchars).blocks == 1)
        #expect(await engine.actionableState.status(of: .roomchars).blocks == 1)
    }

    @Test("the UI hears a feed first seen, and not its repeat")
    func publishesOnChangeOnly() async throws {
        let engine = try ScriptEngine()
        let first = await engine.process(line: "{exits}[ Exits: north ]")
        let repeated = await engine.process(line: "{exits}[ Exits: south ]")
        #expect(states(first.effects).first?.status(of: .exits).isSeen == true)
        #expect(states(repeated.effects).isEmpty)

        let vitals = await engine.applyGMCP(package: "char.vitals", json: "{\"hp\":1}")
        let again = await engine.applyGMCP(package: "char.vitals", json: "{\"hp\":2}")
        #expect(states(vitals).first?.status(of: .charVitals).isSeen == true)
        #expect(states(again).isEmpty)
    }

    @Test("a feed-status change doesn't call onStateChange")
    func noPluginCallForFeedStatus() async throws {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(Spy())
        _ = await engine.process(line: "{roomchars}")
        let closing = await engine.process(line: "{/roomchars}")
        let vitals = await engine.applyGMCP(package: "char.vitals", json: "{}")
        #expect(!(closing.effects + vitals).contains(.echo("state changed")))
        #expect(!states(closing.effects).isEmpty, "the UI still hears it")
    }

    @Test("the registry tells enabled plugins only")
    func registryFanOut() {
        var registry = NativePluginRegistry()
        registry.register(Spy())
        #expect(registry.onStateChange(ActionableState(), changed: []) == [.echo("state changed")])
        _ = registry.setEnabled(false, id: "test.state-spy")
        #expect(registry.onStateChange(ActionableState(), changed: []).isEmpty)
    }

    @Test("connecting resets the state and publishes it")
    func resetOnConnect() async throws {
        let engine = try ScriptEngine()
        _ = await engine.process(line: "{exits}[ Exits: north ]")
        let effects = await engine.connectNativePlugins()
        #expect(states(effects) == [ActionableState()])
        #expect(await engine.actionableState == ActionableState())
    }
}

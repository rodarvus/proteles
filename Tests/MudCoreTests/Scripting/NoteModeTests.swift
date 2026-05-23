import Foundation
@testable import MudCore
import Testing

@Suite("NoteMode — suspend automations while note-writing")
struct NoteModeTests {
    @Test("Entering state 5 suspends; leaving resumes — once per transition")
    func transitions() {
        var plugin = NoteMode()
        // Not writing yet (state 3) → no change.
        #expect(plugin.onGMCP(package: "char.status", json: #"{"state":3,"level":1}"#).isEmpty)

        // Enter note mode.
        let entering = plugin.onGMCP(package: "char.status", json: #"{"state":5,"level":1}"#)
        #expect(entering.first == .setAutomationsSuspended(true))
        #expect(entering.count == 2) // suspend + a coloured note

        // Another state-5 update shouldn't re-fire.
        #expect(plugin.onGMCP(package: "char.status", json: #"{"state":5}"#).isEmpty)

        // Leave note mode.
        let leaving = plugin.onGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(leaving.first == .setAutomationsSuspended(false))
    }

    @Test("Non-status packages are ignored")
    func ignoresOtherPackages() {
        var plugin = NoteMode()
        #expect(plugin.onGMCP(package: "char.vitals", json: #"{"hp":1}"#).isEmpty)
    }
}

@Suite("ScriptEngine — suspension gates the pipeline")
struct ScriptEngineSuspendTests {
    @Test("While suspended: input is verbatim, lines pass through, timers don't fire")
    func suspendedPipeline() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("ouch"), sendText: "flee"))
        try await engine.addAlias(Alias(pattern: .exact("kk"), sendText: "kill mob"))
        _ = try await engine.addTimer(MudTimer(schedule: .after(0), action: .send("tick")))

        await engine.setSuspended(true)
        #expect(await engine.expandInput("kk") == [.send("kk")]) // alias not expanded
        #expect(await engine.process(line: "ouch").effects.isEmpty) // trigger not fired
        #expect(await engine.fireDueTimers(at: Date().addingTimeInterval(1)).isEmpty)

        await engine.setSuspended(false)
        #expect(await engine.expandInput("kk") == [.send("kill mob")]) // alias resumes
        #expect(await engine.process(line: "ouch").effects == [.send("flee")])
    }

    @Test("NoteMode end-to-end: state 5 suspends the engine via applyGMCP")
    func noteModeViaGMCP() async throws {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(NoteMode())
        try await engine.addAlias(Alias(pattern: .exact("kk"), sendText: "kill mob"))

        let effects = await engine.applyGMCP(package: "char.status", json: #"{"state":5}"#)
        #expect(effects.contains(.setAutomationsSuspended(true)))
        // The host would apply the effect; simulate that, then verify the gate.
        await engine.setSuspended(true)
        #expect(await engine.expandInput("kk") == [.send("kk")])
    }
}

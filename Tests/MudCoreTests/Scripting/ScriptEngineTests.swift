import Foundation
@testable import MudCore
import Testing

@Suite("ScriptEngine — line processing")
struct ScriptEngineTests {
    @Test("A send trigger produces a .send effect")
    func sendTrigger() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .wildcard("* arrives"), sendText: "kill %1"))
        let disposition = await engine.process(line: "a goblin arrives")
        #expect(disposition.effects == [.send("kill a goblin")])
        #expect(!disposition.gag)
    }

    @Test("A gag trigger sets gag and drops nothing else")
    func gagTrigger() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("spam"), gag: true))
        let disposition = await engine.process(line: "spammy line")
        #expect(disposition.gag)
        #expect(disposition.effects.isEmpty)
    }

    @Test("A script trigger runs with captures bound to `matches`")
    func scriptTriggerCaptures() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(
            pattern: .regex(#"^(\w+) tells you '(.*)'$"#),
            script: "proteles.send('reply ' .. matches[1] .. ' got: ' .. matches[2])"
        ))
        let disposition = await engine.process(line: "Bob tells you 'hello'")
        #expect(disposition.effects == [.send("reply Bob got: hello")])
    }

    @Test("Named captures are bound to `named`")
    func namedCaptures() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(
            pattern: .regex(#"^You gain (?<amount>\d+) xp$"#),
            script: "proteles.echo('xp: ' .. named.amount)"
        ))
        let disposition = await engine.process(line: "You gain 250 xp")
        #expect(disposition.effects == [.echo("xp: 250")])
    }

    @Test("A non-matching line yields an empty disposition")
    func noMatch() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("zzz"), sendText: "x"))
        let disposition = await engine.process(line: "nothing here")
        #expect(disposition == ScriptEngine.LineDisposition())
    }

    @Test("A throwing trigger script surfaces as a red note")
    func scriptError() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("x"), script: "error('boom')"))
        let disposition = await engine.process(line: "x")
        #expect(disposition.effects.count == 1)
        if case .note(let text, "red", _) = disposition.effects.first {
            #expect(text.contains("boom"))
        } else {
            Issue.record("expected a red error note")
        }
    }

    /// The portal-when-worn bug (Finding 1): dinv registers its wish-capture
    /// trigger via `AddTriggerEx(..., sequence: 0)` so it evaluates before any
    /// co-loaded plugin's stop-on-match (`keep_evaluating="n"`) trigger that also
    /// matches the owned wish lines. Our runtime `AddTriggerEx` path used to drop
    /// the sequence (→ default 100), so the stopper pre-empted dinv's capture and
    /// `dbot.wish.has("Portal")` came back false → dinv removed the wrong slot.
    /// This locks the ordering guarantee the fix depends on: a low-sequence
    /// continuing trigger still fires even though a higher-sequence stop-on-match
    /// trigger matches the same line.
    @Test("A low-sequence trigger fires before a higher-sequence stop-on-match trigger")
    func lowSequenceTriggerWinsOverStopOnMatch() async throws {
        let engine = try ScriptEngine()
        // The "stopper": default sequence 100, stop-on-match (continueEvaluation
        // false), matches everything — like a co-loaded plugin's catch-all.
        try await engine.addTrigger(Trigger(
            pattern: .regex("^(.*)$"),
            sequence: 100,
            continueEvaluation: false,
            sendText: "STOP"
        ))
        // dinv's wish-capture analogue: sequence 0, continues — must still fire.
        try await engine.addTrigger(Trigger(
            pattern: .regex("^(.*)$"),
            sequence: 0,
            continueEvaluation: true,
            sendText: "CAPTURE"
        ))
        let disposition = await engine.process(line: "* a portal")
        #expect(
            disposition.effects.contains(.send("CAPTURE")),
            "sequence-0 capture trigger was pre-empted: \(disposition.effects)"
        )
    }

    @Test("run executes an arbitrary script and returns its effects")
    func runArbitrary() async throws {
        let engine = try ScriptEngine()
        let effects = await engine.run("proteles.echo('hi'); proteles.send('look')")
        #expect(effects == [.echo("hi"), .send("look")])
    }

    @Test("updateTrigger replaces in place — no duplicate registration")
    func updateTriggerReplaces() async throws {
        let engine = try ScriptEngine()
        let id = UUID()
        try await engine.addTrigger(Trigger(id: id, pattern: .substring("a"), sendText: "one"))
        await engine.updateTrigger(Trigger(id: id, pattern: .substring("a"), sendText: "two"))
        let matching = await engine.triggerList.filter { $0.id == id }
        #expect(matching.count == 1)
        #expect(matching.first?.sendText == "two")
    }

    @Test("Concurrent updateTrigger calls never leave duplicates (the #5 multi-fire bug)")
    func concurrentUpdatesStaySingle() async throws {
        let engine = try ScriptEngine()
        let id = UUID()
        try await engine.addTrigger(Trigger(id: id, pattern: .substring("hit"), sendText: "v0"))

        // Simulate the editor firing many live-apply updates as the user types.
        // Atomic updateTrigger means any interleaving still ends with one copy.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    await engine.updateTrigger(
                        Trigger(id: id, pattern: .substring("hit"), sendText: "v\(index)")
                    )
                }
            }
        }
        #expect(await engine.triggerList.count(where: { $0.id == id }) == 1)

        // And the surviving single trigger fires exactly once per matched line.
        let disposition = await engine.process(line: "you hit it")
        #expect(disposition.effects.count(where: { if case .send = $0 { true } else { false } }) == 1)
    }

    @Test("applyGMCP updates the live table and fires gmcp events")
    func applyGMCPRoutesThrough() async throws {
        let engine = try ScriptEngine()
        await engine.run("""
        proteles.onEvent('gmcp.char.vitals', function()
            proteles.send('hp:' .. proteles.gmcp.char.vitals.hp)
        end)
        """)
        let effects = await engine.applyGMCP(package: "char.vitals", json: #"{"hp":42}"#)
        #expect(effects == [.send("hp:42")])
    }
}

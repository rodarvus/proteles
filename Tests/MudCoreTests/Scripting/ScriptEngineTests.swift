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

    @Test("run executes an arbitrary script and returns its effects")
    func runArbitrary() async throws {
        let engine = try ScriptEngine()
        let effects = await engine.run("proteles.echo('hi'); proteles.send('look')")
        #expect(effects == [.echo("hi"), .send("look")])
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("TriggerMatch — substitution")
struct TriggerMatchSubstitutionTests {
    @Test("Numbered and whole-match substitution")
    func numbered() {
        let match = TriggerMatch(whole: "kill rat", captures: ["kill rat", "rat"])
        #expect(match.expand("attack %1!") == "attack rat!")
        #expect(match.expand("[%0]") == "[kill rat]")
    }

    @Test("Named substitution")
    func named() {
        let match = TriggerMatch(whole: "Bob hits you", captures: ["Bob hits you"], named: ["who": "Bob"])
        #expect(match.expand("%<who> is attacking") == "Bob is attacking")
    }

    @Test("Literal percent and unknown sequences pass through")
    func literals() {
        let match = TriggerMatch(whole: "x", captures: ["x"])
        #expect(match.expand("100%% done") == "100% done")
        #expect(match.expand("%z") == "%z")
    }

    @Test("Out-of-range numbered group yields empty")
    func outOfRange() {
        let match = TriggerMatch(whole: "x", captures: ["x"])
        #expect(match.expand("[%5]") == "[]")
    }
}

@Suite("TriggerEngine — pattern types")
struct TriggerEnginePatternTests {
    private func fired(
        _ pattern: TriggerPattern,
        on line: String,
        caseSensitive: Bool = false
    ) throws -> TriggerMatch? {
        var engine = TriggerEngine()
        let trigger = Trigger(pattern: pattern, caseSensitive: caseSensitive)
        try engine.add(trigger)
        return engine.process(line).first?.match
    }

    @Test("substring matches anywhere")
    func substring() throws {
        #expect(try fired(.substring("rabbit"), on: "a fluffy rabbit hops") != nil)
        #expect(try fired(.substring("rabbit"), on: "no match here") == nil)
    }

    @Test("beginsWith matches only at the start")
    func beginsWith() throws {
        #expect(try fired(.beginsWith("You "), on: "You die.") != nil)
        #expect(try fired(.beginsWith("You "), on: "And You die.") == nil)
    }

    @Test("exact requires the whole line")
    func exact() throws {
        #expect(try fired(.exact("ok"), on: "ok") != nil)
        #expect(try fired(.exact("ok"), on: "ok then") == nil)
    }

    @Test("wildcard captures * and ? (anchored)")
    func wildcard() throws {
        let match = try fired(.wildcard("You kill * for ? xp"), on: "You kill a rat for 5 xp")
        #expect(match?.captures == ["You kill a rat for 5 xp", "a rat", "5"])
        #expect(try fired(.wildcard("You kill *"), on: "Someone You kill") == nil) // anchored
    }

    @Test("regex with numbered and named captures")
    func regex() throws {
        let match = try fired(.regex(#"^(\w+) tells you '(?<msg>.*)'$"#), on: "Bob tells you 'hi there'")
        #expect(match?.captures[1] == "Bob")
        #expect(match?.named["msg"] == "hi there")
    }

    @Test("case sensitivity is honoured")
    func caseSensitivity() throws {
        #expect(try fired(.substring("RABBIT"), on: "a rabbit", caseSensitive: false) != nil)
        #expect(try fired(.substring("RABBIT"), on: "a rabbit", caseSensitive: true) == nil)
    }

    @Test("An invalid regex throws")
    func invalidRegex() {
        var engine = TriggerEngine()
        #expect(throws: TriggerEngine.TriggerError.self) {
            try engine.add(Trigger(pattern: .regex("(unclosed")))
        }
    }
}

@Suite("TriggerEngine — evaluation & response")
struct TriggerEngineEvaluationTests {
    @Test("Fires in ascending sequence order")
    func sequenceOrder() throws {
        var engine = TriggerEngine()
        try engine.add(Trigger(pattern: .substring("x"), sequence: 200, sendText: "second"))
        try engine.add(Trigger(pattern: .substring("x"), sequence: 100, sendText: "first"))
        let sends = engine.process("x").map(\.send)
        #expect(sends == ["first", "second"])
    }

    @Test("Equal sequences keep insertion order")
    func stableOrder() throws {
        var engine = TriggerEngine()
        try engine.add(Trigger(pattern: .substring("x"), sequence: 100, sendText: "a"))
        try engine.add(Trigger(pattern: .substring("x"), sequence: 100, sendText: "b"))
        #expect(engine.process("x").map(\.send) == ["a", "b"])
    }

    @Test("continueEvaluation=false stops later triggers; a non-match never does")
    func continueEvaluation() throws {
        var engine = TriggerEngine()
        try engine.add(Trigger(pattern: .substring("no"), sequence: 50, sendText: "skip")) // won't match
        try engine.add(Trigger(
            pattern: .substring("x"),
            sequence: 100,
            continueEvaluation: false,
            sendText: "stop"
        ))
        try engine.add(Trigger(pattern: .substring("x"), sequence: 200, sendText: "never"))
        #expect(engine.process("x").map(\.send) == ["stop"])
    }

    @Test("send text is expanded with captures")
    func sendExpansion() throws {
        var engine = TriggerEngine()
        try engine.add(Trigger(pattern: .wildcard("* arrives"), sendText: "kill %1"))
        #expect(engine.process("a goblin arrives").first?.send == "kill a goblin")
    }

    @Test("gag is reported on the firing")
    func gag() throws {
        var engine = TriggerEngine()
        try engine.add(Trigger(pattern: .substring("spam"), gag: true))
        #expect(engine.process("spam line").first?.gag == true)
    }

    @Test("one-shot triggers fire once then are removed")
    func oneShot() throws {
        var engine = TriggerEngine()
        try engine.add(Trigger(pattern: .substring("boss"), oneShot: true, sendText: "flee"))
        #expect(engine.process("the boss appears").count == 1)
        #expect(engine.process("the boss appears").isEmpty)
        #expect(engine.allTriggers.isEmpty)
    }

    @Test("disabled triggers and groups don't fire")
    func enableAndGroups() throws {
        var engine = TriggerEngine()
        let id = UUID()
        try engine.add(Trigger(id: id, pattern: .substring("x"), sendText: "a"))
        try engine.add(Trigger(pattern: .substring("x"), group: "combat", sendText: "b"))

        engine.setEnabled(false, id: id)
        #expect(engine.process("x").map(\.send) == ["b"])

        engine.setEnabled(true, id: id)
        engine.setGroupEnabled(false, group: "combat")
        #expect(engine.process("x").map(\.send) == ["a"])

        engine.setGroupEnabled(true, group: "combat")
        #expect(engine.process("x").map(\.send) == ["a", "b"])
    }

    @Test("script and captures are surfaced for the host")
    func scriptFiring() throws {
        var engine = TriggerEngine()
        try engine.add(Trigger(pattern: .regex(#"^(\w+) gold$"#), script: "proteles.echo('got gold')"))
        let firing = try #require(engine.process("500 gold").first)
        #expect(firing.script == "proteles.echo('got gold')")
        #expect(firing.match.captures[1] == "500")
    }
}

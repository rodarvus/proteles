import Foundation
@testable import MudCore
import Testing

@Suite("Trigger send-to targets (D-105)")
struct TriggerTargetTests {
    private func disposition(
        _ trigger: Trigger, line: String
    ) async throws -> ScriptEngine.LineDisposition {
        let engine = try ScriptEngine()
        try await engine.addTrigger(trigger)
        return await engine.process(line: line)
    }

    @Test("world (default) → .send; execute → .execute; output → a local note")
    func targetsRoute() async throws {
        let world = try await disposition(
            Trigger(pattern: .substring("ping"), sendText: "pong"), line: "ping"
        )
        #expect(world.effects == [.send("pong")])

        let execute = try await disposition(
            Trigger(pattern: .substring("ping"), sendText: "qw", sendTo: .execute),
            line: "ping"
        )
        #expect(execute.effects == [.execute("qw")])

        let output = try await disposition(
            Trigger(pattern: .wildcard("* tells you *"), sendText: "tell from %1", sendTo: .output),
            line: "Bob tells you hi"
        )
        #expect(output.effects == [.note(text: "tell from Bob", foreground: nil, background: nil)])
    }

    @Test("a stored pre-D-105 trigger (no sendTo key) decodes as send-to-world")
    func decodeCompatibility() throws {
        let old = """
        {"id":"6F1C0E3A-2B7D-4E5F-9A8B-0C1D2E3F4A5B","pattern":{"substring":{"_0":"hp"}},
         "caseSensitive":false,"enabled":true,"sequence":100,
         "continueEvaluation":true,"oneShot":false,"gag":false,"sendText":"score"}
        """
        let trigger = try JSONDecoder().decode(Trigger.self, from: Data(old.utf8))
        #expect(trigger.sendTo == .world)
        #expect(trigger.highlight == nil)
        #expect(trigger.sendText == "score")
    }

    @Test("the pattern match reports its UTF-16 range")
    func matchRange() throws {
        let matcher = try PatternMatcher(pattern: .substring("target"), caseSensitive: false)
        let match = try #require(matcher.match("your target is here"))
        #expect(match.utf16Range == 5..<11)
        #expect(match.whole == "target")
    }
}

@Suite("Trigger highlight (D-105)")
struct TriggerHighlightTests {
    private let yellow = ANSIColor.rgb(red: 255, green: 255, blue: 85)

    @Test("whole-line: every run takes the colour; bold composes; links survive")
    func wholeLine() {
        let link = LineLink(action: .sendCommand("look"))
        let line = Line(id: LineID(1), text: "a shiny thing", runs: [
            StyledRun(utf16Range: 0..<2, style: StyleAttributes(bold: true)),
            StyledRun(
                utf16Range: 2..<7,
                style: StyleAttributes(foreground: .named(.red)),
                link: link
            )
            // 7..<13 uncovered → default style
        ])
        let highlight = TriggerHighlight(foreground: yellow, bold: true, scope: .wholeLine)
        let restyled = LineHighlighter.apply(highlight, to: line, matchRange: nil)

        #expect(restyled.text == line.text)
        for run in restyled.runs {
            #expect(run.style.foreground == yellow)
            #expect(run.style.bold)
        }
        // The hyperlink span is still a link after restyling.
        #expect(restyled.runs.first { $0.utf16Range.lowerBound == 2 }?.link == link)
        // Full coverage, in order, no overlaps.
        #expect(restyled.runs.map(\.utf16Range.lowerBound) == [0, 2, 7])
        #expect(restyled.runs.last?.utf16Range.upperBound == 13)
    }

    @Test("matched-text: only the span is restyled; outside keeps its style")
    func matchedSpan() {
        let line = Line(id: LineID(1), text: "you see a troll here", runs: [
            StyledRun(utf16Range: 0..<20, style: StyleAttributes(foreground: .named(.green)))
        ])
        let highlight = TriggerHighlight(foreground: yellow, scope: .matchedText)
        let restyled = LineHighlighter.apply(highlight, to: line, matchRange: 10..<15)

        let before = restyled.runs.first { $0.utf16Range.contains(0) }
        let span = restyled.runs.first { $0.utf16Range == 10..<15 }
        let after = restyled.runs.first { $0.utf16Range.contains(16) }
        #expect(before?.style.foreground == .named(.green))
        #expect(span?.style.foreground == yellow)
        #expect(after?.style.foreground == .named(.green))
    }

    @Test("a plain line (no runs) gains a run covering the highlight")
    func plainLine() {
        let line = Line(id: LineID(1), text: "plain", runs: [])
        let highlight = TriggerHighlight(foreground: yellow, scope: .wholeLine)
        let restyled = LineHighlighter.apply(highlight, to: line, matchRange: nil)
        #expect(restyled.runs == [
            StyledRun(utf16Range: 0..<5, style: StyleAttributes(foreground: yellow))
        ])
    }

    @Test("end-to-end: a matching trigger sets a restyled replacement line")
    func engineSetsReplacement() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(
            pattern: .substring("troll"),
            highlight: TriggerHighlight(foreground: yellow, scope: .matchedText)
        ))
        let line = Line(id: LineID(7), text: "a troll arrives", runs: [])
        let disposition = await engine.process(line)
        let replacement = try #require(disposition.replacement)
        #expect(replacement.text == "a troll arrives")
        let span = replacement.runs.first { $0.utf16Range == 2..<7 }
        #expect(span?.style.foreground == yellow)
    }

    @Test("no highlight → no replacement (the common path stays untouched)")
    func noHighlightNoReplacement() async throws {
        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("x"), sendText: "y"))
        let disposition = await engine.process(Line(id: LineID(1), text: "x", runs: []))
        #expect(disposition.replacement == nil)
    }
}

@Suite("MUSHclient trigger import — send_to targets (D-105)")
struct TriggerImportTargetTests {
    @Test("send_to 2/10 map to output/execute; 12 stays the script field")
    func sendToMapping() {
        func rule(_ sendTo: Int) -> MUSHclientWorldFile.ScriptRule {
            .init(match: "x", send: "body", sendTo: sendTo, name: "t\(sendTo)")
        }
        let triggers = MUSHclientScriptMapping.triggers(from: [rule(0), rule(2), rule(10), rule(12)])
        #expect(triggers[0].sendTo == .world)
        #expect(triggers[1].sendTo == .output)
        #expect(triggers[2].sendTo == .execute)
        #expect(triggers[3].script == "body")
        #expect(triggers[3].sendText == nil)
    }
}

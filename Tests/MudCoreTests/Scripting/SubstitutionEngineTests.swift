import Foundation
@testable import MudCore
import Testing

@Suite("SubstitutionEngine — #sub / #gag")
struct SubstitutionEngineTests {
    private func line(_ text: String, runs: [StyledRun] = []) -> Line {
        Line(id: LineID(7), text: text, runs: runs)
    }

    private func redRun(_ range: Range<Int>) -> StyledRun {
        StyledRun(utf16Range: range, style: StyleAttributes(foreground: .named(.red)))
    }

    @Test("A gag rule drops a matching line")
    func gag() {
        let engine = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .gag, pattern: "spam")
        ])
        #expect(engine.apply(to: line("this is spam")) == .gag)
        #expect(engine.apply(to: line("clean line")) == .unchanged)
    }

    @Test("A substitution replaces text and reports a replacement line")
    func substitutePlain() {
        let engine = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "potato", replacement: "pants")
        ])
        guard case .replace(let result) = engine.apply(to: line("a potato here")) else {
            Issue.record("expected a replacement"); return
        }
        #expect(result.text == "a pants here")
        #expect(result.id == LineID(7)) // id preserved
    }

    @Test("Replacement inherits the colour at the match start")
    func colourPreserved() {
        // "hi cat" with "cat" (3..<6) red → replace cat→tiger.
        let engine = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "cat", replacement: "tiger")
        ])
        guard case .replace(let result) = engine.apply(to: line("hi cat", runs: [redRun(3..<6)])) else {
            Issue.record("expected a replacement"); return
        }
        #expect(result.text == "hi tiger")
        // "tiger" (5 units) inherits red, remapped to 3..<8.
        #expect(result.runs.count == 1)
        #expect(result.runs[0].utf16Range == 3..<8)
        #expect(result.runs[0].style.foreground == .named(.red))
    }

    @Test("Surrounding colour survives a shorter replacement")
    func surroundingColourSurvives() {
        // "[red]all[/] " — whole "all done" red; replace "done"→"x".
        let engine = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "done", replacement: "x")
        ])
        let input = line("all done", runs: [redRun(0..<8)])
        guard case .replace(let result) = engine.apply(to: input) else {
            Issue.record("expected a replacement"); return
        }
        #expect(result.text == "all x")
        #expect(result.runs[0].utf16Range == 0..<5) // "all x" all red
    }

    @Test("#alone matches only whole words")
    func wholeWord() {
        let engine = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "cat", replacement: "dog", wholeWord: true)
        ])
        #expect(engine.apply(to: line("category")) == .unchanged) // not a whole word
        guard case .replace(let result) = engine.apply(to: line("the cat")) else {
            Issue.record("expected a replacement"); return
        }
        #expect(result.text == "the dog")
    }

    @Test("Case-insensitive by default; #caseSensitive respects case")
    func caseSensitivity() {
        let insensitive = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "hp", replacement: "health")
        ])
        guard case .replace(let r1) = insensitive.apply(to: line("HP low")) else {
            Issue.record("expected match"); return
        }
        #expect(r1.text == "health low")

        let sensitive = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "hp", replacement: "health", caseSensitive: true)
        ])
        #expect(sensitive.apply(to: line("HP low")) == .unchanged)
    }

    @Test("#regex treats the pattern as a regular expression")
    func regex() {
        let engine = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "[0-9]+", replacement: "#", regex: true)
        ])
        guard case .replace(let result) = engine.apply(to: line("you have 1234 gold")) else {
            Issue.record("expected a replacement"); return
        }
        #expect(result.text == "you have # gold")
    }

    @Test("Multiple substitutions apply in order")
    func multiple() {
        let engine = SubstitutionEngine(rules: [
            SubstitutionRule(kind: .substitute, pattern: "a", replacement: "b"),
            SubstitutionRule(kind: .substitute, pattern: "b", replacement: "c")
        ])
        // "a" → "b" → "c": chaining means the first rule's output is re-read.
        guard case .replace(let result) = engine.apply(to: line("a")) else {
            Issue.record("expected a replacement"); return
        }
        #expect(result.text == "c")
    }

    @Test("remove deletes a rule by id")
    func remove() {
        let rule = SubstitutionRule(kind: .gag, pattern: "x")
        var engine = SubstitutionEngine(rules: [rule])
        let removed = engine.remove(id: rule.id)
        #expect(removed)
        #expect(engine.apply(to: line("x")) == .unchanged)
    }
}

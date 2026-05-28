import Foundation
@testable import MudCore
import Testing

@Suite("PatternTester — match + validation")
struct PatternTesterTests {
    @Test("An empty sample line on a valid pattern is .empty")
    func emptyLine() {
        #expect(PatternTester.test(.wildcard("* arrives"), caseSensitive: false, against: "") == .empty)
    }

    @Test("A wildcard pattern reports its numbered captures (%0 whole, %1…)")
    func wildcardCaptures() {
        let result = PatternTester.test(
            .wildcard("* tells you '*'"),
            caseSensitive: false,
            against: "Bob tells you 'hi'"
        )
        guard case .match(let wildcards, _) = result else {
            Issue.record("expected a match, got \(result)")
            return
        }
        #expect(wildcards.first == "Bob tells you 'hi'") // %0
        #expect(wildcards.dropFirst().first == "Bob") // %1
        #expect(Array(wildcards.dropFirst(2)).first == "hi") // %2
    }

    @Test("A non-matching line is .noMatch")
    func noMatch() {
        #expect(PatternTester.test(.exact("xyzzy"), caseSensitive: false, against: "plugh") == .noMatch)
    }

    @Test("Named regex captures are reported under their original names")
    func namedCaptures() {
        let result = PatternTester.test(
            .regex(#"^(?<who>\w+) hits (?<what>\w+)$"#),
            caseSensitive: false,
            against: "goblin hits you"
        )
        guard case .match(_, let named) = result else {
            Issue.record("expected a match, got \(result)")
            return
        }
        #expect(named["who"] == "goblin")
        #expect(named["what"] == "you")
    }

    @Test("A malformed regex is reported as .invalidPattern, even with no sample line")
    func invalidPattern() {
        if case .invalidPattern = PatternTester.test(.regex("(unclosed"), caseSensitive: false, against: "") {
            // expected
        } else {
            Issue.record("expected .invalidPattern")
        }
    }

    @Test("Case sensitivity is honoured")
    func caseSensitivity() {
        #expect(PatternTester.test(.exact("Hello"), caseSensitive: true, against: "hello") == .noMatch)
        if case .match = PatternTester.test(.exact("Hello"), caseSensitive: false, against: "hello") {
            // expected — case-insensitive match
        } else {
            Issue.record("expected a case-insensitive match")
        }
    }
}

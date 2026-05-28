import Foundation

/// The outcome of testing a ``TriggerPattern`` against a sample line — backs
/// the Scripts editor's "Test" affordance and its inline regex validation.
public enum PatternTestResult: Equatable, Sendable {
    /// The pattern failed to compile (a malformed regex). Carries the source
    /// the matcher tried to compile, for an inline hint.
    case invalidPattern(String)
    /// No sample line entered yet (the pattern is valid).
    case empty
    /// The pattern compiled but didn't match the sample line.
    case noMatch
    /// The pattern matched. `wildcards` are the numbered captures as the
    /// scripting side sees them — index 0 = the whole match (`%0`), 1… = the
    /// groups (`%1`…). `named` holds named-group captures under their original
    /// names.
    case match(wildcards: [String], named: [String: String])
}

/// Pure helper (reusing ``PatternMatcher``) that tells the editor whether a
/// pattern compiles and what it captures from a sample line. No UI, no engine
/// state — fully unit-testable.
public enum PatternTester {
    public static func test(
        _ pattern: TriggerPattern,
        caseSensitive: Bool,
        against line: String
    ) -> PatternTestResult {
        let matcher: PatternMatcher
        do {
            matcher = try PatternMatcher(pattern: pattern, caseSensitive: caseSensitive)
        } catch PatternMatcher.MatchError.invalidPattern(let source) {
            return .invalidPattern(source)
        } catch {
            return .invalidPattern(pattern.regexSource())
        }
        guard !line.isEmpty else { return .empty }
        guard let match = matcher.match(line) else { return .noMatch }
        return .match(wildcards: match.captures, named: match.named)
    }
}

import Foundation

/// Compiles a ``TriggerPattern`` to a cached `NSRegularExpression` and
/// matches lines against it, producing a ``TriggerMatch`` with numbered and
/// named captures. Shared by ``TriggerEngine`` (output side) and
/// ``AliasEngine`` (input side).
struct PatternMatcher {
    enum MatchError: Error, Equatable {
        case invalidPattern(String)
    }

    private let regex: NSRegularExpression
    private let names: [String]

    init(pattern: TriggerPattern, caseSensitive: Bool) throws {
        let source = pattern.regexSource()
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: source, options: options) else {
            throw MatchError.invalidPattern(source)
        }
        self.regex = regex
        names = Self.capturedGroupNames(in: source)
    }

    /// First match of the pattern in `line`, or `nil`.
    func match(_ line: String) -> TriggerMatch? {
        let text = line as NSString
        let range = NSRange(location: 0, length: text.length)
        guard let result = regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }
        var captures: [String] = []
        for index in 0..<result.numberOfRanges {
            let groupRange = result.range(at: index)
            captures.append(groupRange.location == NSNotFound ? "" : text.substring(with: groupRange))
        }
        var named: [String: String] = [:]
        for name in names {
            let namedRange = result.range(withName: name)
            named[name] = namedRange.location == NSNotFound ? "" : text.substring(with: namedRange)
        }
        return TriggerMatch(whole: captures.first ?? "", captures: captures, named: named)
    }

    /// Names of `(?<name>…)` capture groups in a regex source.
    private static let namePattern = try? NSRegularExpression(
        pattern: #"\(\?P?<([A-Za-z_][A-Za-z0-9_]*)>"#
    )

    private static func capturedGroupNames(in source: String) -> [String] {
        guard let namePattern else { return [] }
        let text = source as NSString
        let range = NSRange(location: 0, length: text.length)
        return namePattern.matches(in: source, range: range).map {
            text.substring(with: $0.range(at: 1))
        }
    }
}

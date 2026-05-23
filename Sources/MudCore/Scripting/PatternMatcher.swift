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
    /// (ICU group name → original name). ICU rejects names with underscores or
    /// a leading digit (PCRE allows them, and Aardwolf plugins like
    /// Search-and-Destroy use `(?<mob_name>…)` heavily), so every named group
    /// is rewritten to a safe `gN` and mapped back here.
    private let nameMapping: [(icu: String, original: String)]

    init(pattern: TriggerPattern, caseSensitive: Bool) throws {
        let (source, mapping) = Self.sanitizeNamedGroups(pattern.regexSource())
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: source, options: options) else {
            throw MatchError.invalidPattern(source)
        }
        self.regex = regex
        nameMapping = mapping
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
        for entry in nameMapping {
            let namedRange = result.range(withName: entry.icu)
            named[entry.original] = namedRange.location == NSNotFound
                ? "" : text.substring(with: namedRange)
        }
        return TriggerMatch(whole: captures.first ?? "", captures: captures, named: named)
    }

    /// Matches a named-group opener `(?<name>` / `(?P<name>`. The name class
    /// excludes `=`/`!`, so lookbehinds `(?<=…)`/`(?<!…)` are left alone.
    private static let namePattern = try? NSRegularExpression(
        pattern: #"\(\?P?<([A-Za-z_][A-Za-z0-9_]*)>"#
    )

    /// Rewrite every `(?<name>` to an ICU-safe `(?<gN>`, returning the new
    /// source and the `gN → name` mapping so captures can be reported under
    /// their original names. Sources with no named groups pass through.
    static func sanitizeNamedGroups(_ source: String) -> (String, [(icu: String, original: String)]) {
        guard let namePattern else { return (source, []) }
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        let matches = namePattern.matches(in: source, range: full)
        guard !matches.isEmpty else { return (source, []) }

        var result = ""
        var cursor = 0
        var mapping: [(icu: String, original: String)] = []
        for (index, match) in matches.enumerated() {
            let icu = "g\(index)"
            let original = text.substring(with: match.range(at: 1))
            result += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "(?<\(icu)>"
            cursor = match.range.location + match.range.length
            mapping.append((icu, original))
        }
        result += text.substring(from: cursor)
        return (result, mapping)
    }
}

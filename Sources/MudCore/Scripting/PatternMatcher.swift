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
        let (named, mapping) = Self.sanitizeNamedGroups(pattern.regexSource())
        let source = Self.escapeLiteralBraces(named)
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

    /// Escape `{`/`}` that don't form a valid `{n}`/`{n,}`/`{n,m}` quantifier,
    /// so they match literally. ICU (NSRegularExpression) rejects a stray `{`
    /// as a malformed quantifier and the whole pattern fails to compile; PCRE
    /// (what MUSHclient uses) treats it as a literal. Aardwolf plugins rely on
    /// that — dinv's command-queue fence matches `^{ DINV fence N }$`, so
    /// without this its fence trigger never compiles and the build deadlocks.
    /// Already-escaped `\{` and real quantifiers are preserved.
    static func escapeLiteralBraces(_ source: String) -> String {
        let chars = Array(source)
        var result = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                result.append(char)
                result.append(chars[index + 1])
                index += 2
            } else if char == "{", let end = validQuantifierEnd(chars, from: index) {
                result.append(contentsOf: chars[index...end])
                index = end + 1
            } else if char == "{" || char == "}" {
                result.append("\\")
                result.append(char)
                index += 1
            } else {
                result.append(char)
                index += 1
            }
        }
        return result
    }

    /// If `chars[start]` (`{`) opens a valid quantifier (`{n}`, `{n,}`,
    /// `{n,m}`), return the index of its closing `}`; otherwise `nil`.
    private static func validQuantifierEnd(_ chars: [Character], from start: Int) -> Int? {
        var index = start + 1
        let digitsStart = index
        while index < chars.count, chars[index].isNumber {
            index += 1
        }
        guard index > digitsStart else { return nil } // need at least one digit
        if index < chars.count, chars[index] == "," {
            index += 1
            while index < chars.count, chars[index].isNumber {
                index += 1
            }
        }
        return (index < chars.count && chars[index] == "}") ? index : nil
    }
}

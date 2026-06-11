import Foundation

/// A user-defined text substitution or gag (the `#sub`/`#gag` feature,
/// ported from `aard_text_substitution`). Pure value type; persisted and
/// applied by ``SubstitutionEngine``.
public struct SubstitutionRule: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// Replace matches of ``pattern`` with ``replacement``.
        case substitute
        /// Drop lines that match ``pattern`` from the output.
        case gag
    }

    public let id: UUID
    public var kind: Kind
    /// The text (or regex source, when ``regex``) to match.
    public var pattern: String
    /// The replacement text (literal). Ignored for ``Kind/gag``.
    public var replacement: String
    /// Treat ``pattern`` as a regular expression (`#regex`).
    public var regex: Bool
    /// Match only at word boundaries (`#alone`).
    public var wholeWord: Bool
    /// Case-sensitive matching (the inverse of `#nocase`; default false).
    public var caseSensitive: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        pattern: String,
        replacement: String = "",
        regex: Bool = false,
        wholeWord: Bool = false,
        caseSensitive: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.replacement = replacement
        self.regex = regex
        self.wholeWord = wholeWord
        self.caseSensitive = caseSensitive
        self.enabled = enabled
    }
}

/// Applies ``SubstitutionRule``s to a styled ``Line``. Substitutions
/// preserve per-segment colour: replacement text inherits the style at the
/// start of each match (matching how `aard_text_substitution` recolours).
/// Gags take precedence — a line matching any enabled gag is dropped.
///
/// A pure value type, fully unit-testable; the ``TextSubstitution`` native
/// plugin wraps it and the host applies the outcome.
public struct SubstitutionEngine: Sendable {
    public enum Outcome: Equatable, Sendable {
        case unchanged
        case gag
        case replace(Line)
    }

    public private(set) var rules: [SubstitutionRule]

    public init(rules: [SubstitutionRule] = []) {
        self.rules = rules
    }

    public var substitutions: [SubstitutionRule] {
        rules.filter { $0.kind == .substitute }
    }

    public var gags: [SubstitutionRule] {
        rules.filter { $0.kind == .gag }
    }

    public mutating func add(_ rule: SubstitutionRule) {
        rules.append(rule)
    }

    /// Remove a rule by id. Returns true if one was removed.
    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        let before = rules.count
        rules.removeAll { $0.id == id }
        return rules.count != before
    }

    public mutating func setRules(_ rules: [SubstitutionRule]) {
        self.rules = rules
    }

    /// Run `line` through the rules: gag if any gag matches, otherwise apply
    /// every substitution in order and return a recoloured replacement when
    /// the text changed.
    public func apply(to line: Line) -> Outcome {
        for gag in gags where gag.enabled && matches(gag, in: line.text) {
            return .gag
        }
        var styled = StyledText(line: line)
        var changed = false
        for rule in substitutions where rule.enabled {
            if styled.substitute(rule) { changed = true }
        }
        guard changed else { return .unchanged }
        return .replace(styled.line(id: line.id, timestamp: line.timestamp))
    }

    // MARK: - Matching

    private func matches(_ rule: SubstitutionRule, in text: String) -> Bool {
        guard let regex = Self.regularExpression(for: rule) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Compiled-pattern cache. `apply(to:)` runs per incoming line and used
    /// to recompile every enabled rule's regex twice per line (gag check +
    /// substitute) — O(rules × lines) compile churn on the hot path (2026-06
    /// audit). Keyed by the full compile inputs, so editing a rule simply
    /// misses into a fresh entry; `NSCache` is documented thread-safe and
    /// evicts under memory pressure, hence `nonisolated(unsafe)` is sound.
    private nonisolated(unsafe) static let compiledPatterns =
        NSCache<NSString, NSRegularExpression>()

    fileprivate static func regularExpression(for rule: SubstitutionRule) -> NSRegularExpression? {
        var pattern = rule.regex ? rule.pattern : NSRegularExpression.escapedPattern(for: rule.pattern)
        if rule.wholeWord { pattern = "\\b" + pattern + "\\b" }
        let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
        let key = "\(options.rawValue):\(pattern)" as NSString
        if let cached = compiledPatterns.object(forKey: key) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        compiledPatterns.setObject(compiled, forKey: key)
        return compiled
    }
}

/// A line decomposed into per-UTF-16-unit styles, so substitutions can
/// rewrite the text while carrying colour along.
private struct StyledText {
    /// One style per UTF-16 unit (`nil` = default).
    private var styles: [StyleAttributes?]
    private var mutableText: String

    init(line: Line) {
        let nsText = line.text as NSString
        mutableText = line.text
        var styles = [StyleAttributes?](repeating: nil, count: nsText.length)
        for run in line.runs {
            for index in run.utf16Range where index < styles.count {
                styles[index] = run.style
            }
        }
        self.styles = styles
    }

    /// Apply one substitution rule across all matches. Returns true if any
    /// match was rewritten.
    mutating func substitute(_ rule: SubstitutionRule) -> Bool {
        let source = mutableText as NSString
        guard let regex = SubstitutionEngine.regularExpression(for: rule) else { return false }
        let matches = regex.matches(in: mutableText, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return false }

        let replacement = rule.replacement as NSString
        var newText = ""
        var newStyles: [StyleAttributes?] = []
        var cursor = 0
        for match in matches {
            let start = match.range.location
            if start > cursor {
                appendGap(from: cursor, to: start, source: source, into: &newText, styles: &newStyles)
            }
            // Replacement inherits the style at the match start.
            let style = start < styles.count ? styles[start] : nil
            newText += replacement as String
            newStyles.append(contentsOf: [StyleAttributes?](repeating: style, count: replacement.length))
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            appendGap(from: cursor, to: source.length, source: source, into: &newText, styles: &newStyles)
        }
        mutableText = newText
        styles = newStyles
        return true
    }

    private func appendGap(
        from: Int,
        to: Int,
        source: NSString,
        into text: inout String,
        styles newStyles: inout [StyleAttributes?]
    ) {
        text += source.substring(with: NSRange(location: from, length: to - from))
        for index in from..<to {
            newStyles.append(index < styles.count ? styles[index] : nil)
        }
    }

    /// Rebuild a styled ``Line`` by coalescing equal adjacent styles.
    func line(id: LineID, timestamp: Date) -> Line {
        var runs: [StyledRun] = []
        var index = 0
        while index < styles.count {
            guard let style = styles[index], !style.isDefault else { index += 1; continue }
            var end = index + 1
            while end < styles.count, styles[end] == style {
                end += 1
            }
            runs.append(StyledRun(utf16Range: index..<end, style: style))
            index = end
        }
        return Line(id: id, timestamp: timestamp, text: mutableText, runs: runs)
    }
}

import Foundation

/// Best-effort human-readable command hints for a library plugin (D-107),
/// derived from the alias patterns it declares — the closest thing a
/// MUSHclient plugin has to a command list. Capture groups and wildcards
/// flatten to `…`; anchors and escapes are stripped; catch-alls and
/// non-command shapes are dropped. Pure.
public enum PluginCommandHints {
    /// Deduplicated, alphabetised hints from `aliases` — e.g.
    /// `^dinv\s+(.+)$` → `dinv …`.
    public static func from(aliases: [Alias]) -> [String] {
        let hints = aliases.compactMap { humanize($0.pattern) }
        return Set(hints).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// One pattern's hint, or nil when it doesn't look like a typed command
    /// (a catch-all, or noise left after simplification).
    static func humanize(_ pattern: TriggerPattern) -> String? {
        var text: String = switch pattern {
        case .substring(let value), .beginsWith(let value), .exact(let value),
             .wildcard(let value), .regex(let value):
            value
        }
        if case .regex = pattern {
            text = simplifyRegex(text)
        }
        // Wildcard `*`/`?` placeholders (and any regex leftovers) become `…`.
        text = text.replacingOccurrences(of: "*", with: "…")
        text = text.replacingOccurrences(of: "?", with: "…")
        text = text.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // Collapse runs of ellipses left by adjacent groups.
        while text.contains("… …") {
            text = text.replacingOccurrences(of: "… …", with: "…")
        }
        // A command starts with a word character — drop catch-alls (`…`),
        // empty results, and patterns that simplified to punctuation.
        guard let first = text.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first)
        else { return nil }
        return text
    }

    /// Strip the regex furniture a typed-command alias typically carries:
    /// anchors, capture groups (→ `…`), whitespace classes (→ a space),
    /// optional markers, and backslash escapes.
    private static func simplifyRegex(_ source: String) -> String {
        var text = source
        if text.hasPrefix("^") { text.removeFirst() }
        if text.hasSuffix("$") { text.removeLast() }
        // Any parenthesised group — `(.*)`, `(\d+)`, `(?:a|b)` — becomes `…`.
        // (?<name>…) included. Nested groups collapse over two passes.
        for _ in 0..<2 {
            text = text.replacingOccurrences(
                of: #"\([^()]*\)"#, with: "…", options: .regularExpression
            )
        }
        // `\s+` / `\s*` are word separators.
        text = text.replacingOccurrences(
            of: #"\\s[+*]?"#, with: " ", options: .regularExpression
        )
        // Optional single characters (`s?`) — keep the character, drop the `?`
        // handled by the generic `?` → `…`? No: drop the marker first so
        // "quests?" reads "quests" rather than "quest…".
        text = text.replacingOccurrences(
            of: #"(\w)\?"#, with: "$1", options: .regularExpression
        )
        // Character classes (`[abc]`, `[^x]+`) become `…`.
        text = text.replacingOccurrences(
            of: #"\[[^\]]*\][+*?]?"#, with: "…", options: .regularExpression
        )
        // Remaining quantifiers and escapes.
        text = text.replacingOccurrences(of: #"[+*]"#, with: "…", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\", with: "")
        return text
    }
}

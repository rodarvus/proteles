import Foundation

/// Extracting the leading **literal command words** an alias pattern fires on —
/// the verb plus any fixed subcommands before the first wildcard / capture /
/// metacharacter. Drives plugin verb + subcommand completion (#31): MUSHclient
/// plugins register their grammar as per-subcommand aliases, e.g.
/// `^[ ]*dinv[ ]+put[ ]+(.*?)$` → `["dinv", "put"]`, `^ldb level(?: …)?$` →
/// `["ldb", "level"]`, `^ldb$` → `["ldb"]`. So harvesting these tokens across a
/// plugin's aliases recovers its command tree with no per-plugin hardcoding.
public extension TriggerPattern {
    /// The leading literal tokens (verb first, then fixed subcommands),
    /// lowercased. Empty for an unanchored substring pattern (no reliable verb).
    var commandTokens: [String] {
        switch self {
        case .exact(let text), .beginsWith(let text):
            Self.literalTokens(text)
        case .wildcard(let text):
            // Literal prefix up to the first MUSHclient wildcard.
            Self.literalTokens(String(text.prefix { $0 != "*" && $0 != "?" }))
        case .regex(let pattern):
            Self.regexLiteralTokens(pattern)
        case .substring:
            []
        }
    }

    /// The leading command word (verb), or `nil`. `kk *` → `kk`.
    var leadingVerb: String? {
        commandTokens.first
    }

    // MARK: - Extraction

    /// Leading clean word tokens of a plain literal, stopping at the first token
    /// that isn't a clean command word (letters/digits/`'`).
    private static func literalTokens(_ text: String) -> [String] {
        var result: [String] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let word = token.lowercased()
            guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" })
            else { break }
            result.append(word)
        }
        return result
    }

    /// Leading literal tokens of an anchored regex alias. Whitespace separators
    /// (a literal space, `\s`, or a whitespace-only class like `[ ]*`/`[ \t]+`)
    /// end a token; the first capture/quantifier/metacharacter ends the scan.
    private static func regexLiteralTokens(_ pattern: String) -> [String] {
        let chars = Array(pattern)
        var index = chars.startIndex
        if index < chars.endIndex, chars[index] == "^" { index += 1 }

        var tokens: [String] = []
        var current = ""
        while index < chars.endIndex {
            let char = chars[index]
            if char.isLetter || char.isNumber || char == "'" {
                current.append(char)
                index += 1
                continue
            }
            // A non-word char: either a whitespace separator (end this token and
            // skip it) or a real metacharacter (stop the scan entirely).
            guard let width = separatorWidth(chars, at: index) else { break }
            if !current.isEmpty { tokens.append(current.lowercased()); current = "" }
            index += width
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }

    /// If `chars[index]` begins a whitespace **separator** — a literal space,
    /// `\s`, or a whitespace-only class (`[ ]`, `[ \t]`, `[\s]`), each with an
    /// optional `*`/`+`/`?` — return how many characters it spans. `nil` for a
    /// real metacharacter (the scan stops there).
    private static func separatorWidth(_ chars: [Character], at index: Int) -> Int? {
        switch chars[index] {
        case " ":
            return 1
        case "\\":
            guard index + 1 < chars.endIndex, chars[index + 1] == "s" else { return nil }
            return 2 + quantifierWidth(chars, at: index + 2)
        case "[":
            guard let close = chars[index...].firstIndex(of: "]"),
                  isWhitespaceClass(String(chars[(index + 1)..<close]))
            else { return nil }
            return (close - index + 1) + quantifierWidth(chars, at: close + 1)
        default:
            return nil
        }
    }

    /// 1 if `chars[index]` is a regex quantifier (`*`/`+`/`?`), else 0.
    private static func quantifierWidth(_ chars: [Character], at index: Int) -> Int {
        index < chars.endIndex && "*+?".contains(chars[index]) ? 1 : 0
    }

    /// Whether a regex char-class body matches only whitespace (`[ ]`, `[ \t]`,
    /// `[\s]`) — treated as a token separator rather than a literal class.
    private static func isWhitespaceClass(_ inner: String) -> Bool {
        let stripped = inner.replacingOccurrences(of: "\\", with: "")
        let whitespaceish: Set<Character> = [" ", "\t", "s", "t", "n", "r"]
        return !stripped.isEmpty && stripped.allSatisfy { whitespaceish.contains($0) }
    }
}

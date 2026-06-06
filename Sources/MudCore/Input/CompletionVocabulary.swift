import Foundation

/// Word-level command-line completion (PLAN.md §8.4), the model behind the
/// input box's Tab completion and ghost hint. Pure value type, unit-testable
/// without the UI.
///
/// Completes the **current word** (the token ending at the caret) — not the
/// whole line — from a ranked vocabulary, the way Mudlet and iTerm2 complete
/// from words on screen. Three sources, in priority order:
///
///   1. **Context** — live game nouns (room exits/players, group members,
///      channel names, room-name words). Most relevant to "now"; ranked first.
///   2. **Recent** — words harvested from recent output, most-recent first.
///   3. **Verbs** — command verbs + the user's aliases, offered **only when
///      completing the first word** (the verb position).
///
/// The view owns one instance, refreshing the source lists as scrollback / GMCP
/// change, and asks it for the ghost hint (best match) and the Tab cycle list.
public struct CompletionVocabulary: Sendable, Equatable {
    /// Live game nouns — room exits, players, group members, channel names,
    /// room-name words. Highest priority. Order is preserved as supplied.
    public var contextWords: [String]
    /// Words harvested from recent output, **most-recent first**.
    public var recentWords: [String]
    /// Command verbs + user aliases, offered only for the first word.
    public var verbs: [String]

    /// Shortest token worth completing (a 1-char word completes to noise).
    public let minimumWordLength: Int

    /// Recent-output words are the noisiest source: for a very short prefix they
    /// surface arbitrary words (e.g. `say hello :D` breaks on `:`, leaving a
    /// 1-char `D` that "completed" to *Dirt*). So they only contribute once the
    /// prefix is at least this long. Curated sources (context, verbs) still
    /// complete short prefixes — `n` → `north` stays useful (#31).
    public let recentWordMinPrefix: Int

    public init(
        contextWords: [String] = [],
        recentWords: [String] = [],
        verbs: [String] = [],
        minimumWordLength: Int = 2,
        recentWordMinPrefix: Int = 2
    ) {
        self.contextWords = contextWords
        self.recentWords = recentWords
        self.verbs = verbs
        self.minimumWordLength = max(minimumWordLength, 1)
        self.recentWordMinPrefix = max(recentWordMinPrefix, 1)
    }

    /// Ranked, deduped completions for `prefix` (the current word). A candidate
    /// qualifies when it begins with `prefix` (case-insensitive) and is strictly
    /// longer (so an already-complete word isn't "completed" to itself).
    /// Order: context, then recent, then — only if `isFirstWord` — verbs. The
    /// first match is the ghost hint; the whole list is the Tab cycle.
    /// Original casing of the first occurrence is preserved.
    public func completions(forWord prefix: String, isFirstWord: Bool) -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let needle = prefix.lowercased()

        var seen: Set<String> = []
        var result: [String] = []
        // Curated sources first — context nouns, then (first word only) verbs;
        // the noisy recent-output source ranks last and is gated to longer
        // prefixes (#31).
        var sources = [contextWords]
        if isFirstWord { sources.append(verbs) }
        if prefix.count >= recentWordMinPrefix { sources.append(recentWords) }
        for source in sources {
            for word in source {
                guard word.count >= minimumWordLength, word.count > prefix.count else { continue }
                guard word.lowercased().hasPrefix(needle) else { continue }
                guard seen.insert(word.lowercased()).inserted else { continue }
                result.append(word)
            }
        }
        return result
    }

    /// The trailing text to show as the as-you-type ghost hint (#13): the best
    /// completion for `prefix` with the already-typed portion dropped, or `nil`
    /// when there's nothing to suggest. It's the tail of the same top match Tab
    /// would fill (in that match's own casing), so the ghost and Tab agree.
    public func ghostSuffix(forWord prefix: String, isFirstWord: Bool) -> String? {
        guard let best = completions(forWord: prefix, isFirstWord: isFirstWord).first else { return nil }
        let suffix = String(best.dropFirst(prefix.count)) // best is strictly longer, prefix-matched
        return suffix.isEmpty ? nil : suffix
    }
}

/// Caret-relative word extraction + a scrollback word harvester — the
/// text-manipulation primitives the view and ``CompletionVocabulary`` share.
public enum InputCompletion {
    /// Characters that make up a "word" for completion: letters, digits, and
    /// the apostrophe (MUD spell targets like `mage's`). Everything else —
    /// spaces, punctuation, `.` (so `2.sword` completes `sword`) — is a break.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
    }

    /// The current word: the maximal run of word characters **ending at**
    /// `caret` (a UTF-16-style offset clamped into `text`). Returns the word and
    /// its range so the caller can replace just that span. `nil` when the caret
    /// follows a non-word character (nothing to complete — e.g. just typed a
    /// space), matching Mudlet's "ends with space → no completion".
    public static func currentWord(
        in text: String, caret: Int
    ) -> (word: String, range: Range<String.Index>)? {
        let clamped = max(0, min(caret, text.count))
        let caretIndex = text.index(text.startIndex, offsetBy: clamped)
        var start = caretIndex
        while start > text.startIndex {
            let prev = text.index(before: start)
            guard let scalar = text[prev].unicodeScalars.first, isWordCharacter(scalar) else { break }
            start = prev
        }
        guard start < caretIndex else { return nil }
        return (String(text[start..<caretIndex]), start..<caretIndex)
    }

    /// True when the current word (the one ending at `caret`) is the line's
    /// first word — i.e. only whitespace precedes it. Drives verb completion.
    public static func isFirstWord(in text: String, caret: Int) -> Bool {
        guard let (_, range) = currentWord(in: text, caret: caret) else {
            return text[..<text.index(text.startIndex, offsetBy: max(0, min(caret, text.count)))]
                .allSatisfy(\.isWhitespace)
        }
        return text[..<range.lowerBound].allSatisfy(\.isWhitespace)
    }

    /// Harvest candidate words from recent output `lines` (most-recent line
    /// last, as scrollback stores them), returning them **most-recent first**
    /// and de-duplicated case-insensitively. Splits on non-word characters and
    /// drops anything shorter than `minLength`. Bounded to `limit` words so a
    /// long session can't grow this without end.
    public static func harvestWords(
        from lines: [String],
        minLength: Int = 3,
        limit: Int = 600
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for line in lines.reversed() {
            for token in line.split(whereSeparator: { !isWordCharacter($0.unicodeScalars.first ?? " ") }) {
                let word = String(token)
                guard word.count >= minLength else { continue }
                guard seen.insert(word.lowercased()).inserted else { continue }
                result.append(word)
                if result.count >= limit { return result }
            }
        }
        return result
    }
}

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
    /// Player/people names (group members, recent speakers) — offered for the
    /// **recipient** argument of a directed channel (`tell <who>`). Order preserved.
    public var playerWords: [String]
    /// Per-verb argument sources (#32), keyed by ``CommandArgumentKind``: item
    /// names, mapper room names, spell names, room exits/directions. Cached by the
    /// app (refreshed on GMCP/DB change), not queried per keystroke.
    public var argumentSources: [CommandArgumentKind: [String]]
    /// Broadcast channel verbs (gossip/chat/say/…): once the line's verb is one
    /// of these, the argument is a free-text message — no ghosting (#31).
    public var broadcastChannels: Set<String>
    /// Directed channel verbs (tell/whisper/page/…): the first argument is a
    /// recipient (complete from ``playerWords``); the rest is a message (no ghost).
    public var directedChannels: Set<String>
    /// Installed plugins' subcommands (#31), keyed by verb: `dinv` →
    /// `[build, put, refresh, …]`. Completes the **first argument** of a plugin
    /// verb. Harvested from the plugins' alias grammar.
    public var pluginSubcommands: [String: [String]]

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
        playerWords: [String] = [],
        argumentSources: [CommandArgumentKind: [String]] = [:],
        broadcastChannels: Set<String> = [],
        directedChannels: Set<String> = [],
        pluginSubcommands: [String: [String]] = [:],
        minimumWordLength: Int = 2,
        recentWordMinPrefix: Int = 2
    ) {
        self.contextWords = contextWords
        self.recentWords = recentWords
        self.verbs = verbs
        self.playerWords = playerWords
        self.pluginSubcommands = pluginSubcommands
        self.argumentSources = argumentSources
        self.broadcastChannels = Set(broadcastChannels.map { $0.lowercased() })
        self.directedChannels = Set(directedChannels.map { $0.lowercased() })
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
        // Curated sources first — context nouns, then (first word only) verbs;
        // the noisy recent-output source ranks last and is gated to longer
        // prefixes (#31).
        var sources = [contextWords]
        if isFirstWord { sources.append(verbs) }
        if prefix.count >= recentWordMinPrefix { sources.append(recentWords) }
        return rank(prefix, sources: sources)
    }

    /// Ranked, deduped matches for `prefix` across `sources` (in order). A
    /// candidate begins with `prefix` (case-insensitive) and is strictly longer.
    private func rank(_ prefix: String, sources: [[String]]) -> [String] {
        let needle = prefix.lowercased()
        var seen: Set<String> = []
        var result: [String] = []
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

    /// Line- and position-aware completions for the word ending at `caret` (#31).
    /// Word 0 (the verb) completes from verbs + context. For an **argument**,
    /// behaviour is verb-kind-aware:
    ///   - broadcast channel (gossip/say/…) → none (it's a free-text message);
    ///   - directed channel (tell/page/…) → player names for the recipient
    ///     (word 1), then none for the message body;
    ///   - any other command → context + recent (the regular argument path;
    ///     #32 will refine this per-verb).
    public func completions(inLine line: String, caret: Int) -> [String] {
        guard let (word, _) = InputCompletion.currentWord(in: line, caret: caret) else { return [] }
        let index = InputCompletion.wordIndex(in: line, caret: caret)
        if index == 0 { return completions(forWord: word, isFirstWord: true) }
        let verb = (InputCompletion.firstWord(in: line) ?? "").lowercased()
        if directedChannels.contains(verb) {
            return index == 1 ? rank(word, sources: [playerWords]) : []
        }
        if broadcastChannels.contains(verb) { return [] }
        // Plugin subcommands (#31): the first argument of a plugin verb completes
        // from the subcommands harvested from that plugin's aliases — `dinv b`→
        // `build`, `ldb le`→`level`.
        if index == 1, let subs = pluginSubcommands[verb], !subs.isEmpty {
            return rank(word, sources: [subs])
        }
        // Per-verb argument source (#32): get→item, goto→room, cast→spell,
        // open→exit, …. Players come from the channel paths above. When the
        // curated source has data we use it; when it's empty (the pipeline isn't
        // wired/populated yet) we fall back to generic context/recent rather than
        // offer nothing.
        if let kind = CommandArguments.argumentKind(verb: verb, argumentIndex: index - 1) {
            let source = kind == .player ? playerWords : (argumentSources[kind] ?? [])
            if !source.isEmpty { return rank(word, sources: [source]) }
        }
        return completions(forWord: word, isFirstWord: false)
    }

    /// The as-you-type ghost suffix for the word ending at `caret`, applying the
    /// same line/position/kind rules as ``completions(inLine:caret:)``.
    public func ghostSuffix(inLine line: String, caret: Int) -> String? {
        guard let (word, _) = InputCompletion.currentWord(in: line, caret: caret),
              let best = completions(inLine: line, caret: caret).first
        else { return nil }
        let suffix = String(best.dropFirst(word.count))
        return suffix.isEmpty ? nil : suffix
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

    /// The 0-based index of the word ending at `caret` among the line's words
    /// (0 = the verb, 1 = its first argument, …). Counts word-runs before the
    /// current word; `0` when there's no current word.
    public static func wordIndex(in text: String, caret: Int) -> Int {
        guard let (_, range) = currentWord(in: text, caret: caret) else { return 0 }
        return text[..<range.lowerBound]
            .split(whereSeparator: { !isWordCharacter($0.unicodeScalars.first ?? " ") })
            .count
    }

    /// The line's first word (the verb), or `nil` if the line has none yet.
    public static func firstWord(in text: String) -> String? {
        text.split(whereSeparator: { !isWordCharacter($0.unicodeScalars.first ?? " ") })
            .first
            .map(String.init)
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

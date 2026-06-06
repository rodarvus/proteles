@testable import MudCore
import Testing

@Suite("CompletionVocabulary — word-level completion")
struct CompletionVocabularyTests {
    @Test("Ranks context before recent; verbs only for the first word")
    func ranking() {
        let vocab = CompletionVocabulary(
            contextWords: ["Galadon"],
            recentWords: ["galleon", "gargoyle"],
            verbs: ["get", "give"]
        )
        // Non-first word: context + recent only, context first.
        #expect(vocab.completions(forWord: "ga", isFirstWord: false) == ["Galadon", "galleon", "gargoyle"])
        // First word: verbs appended after context/recent.
        #expect(vocab.completions(forWord: "g", isFirstWord: true).contains("get"))
        #expect(!vocab.completions(forWord: "g", isFirstWord: false).contains("get"))
    }

    @Test("Case-insensitive match, strictly longer, deduped by lowercase")
    func matchingRules() {
        let vocab = CompletionVocabulary(
            contextWords: ["Galadon", "galadon", "GAL"],
            recentWords: []
        )
        // "GAL" is not strictly longer than "gal" (3 == 3) → excluded; the two
        // Galadon spellings dedupe to the first-seen casing.
        #expect(vocab.completions(forWord: "gal", isFirstWord: false) == ["Galadon"])
        // Prefix is case-insensitive.
        #expect(vocab.completions(forWord: "GAL", isFirstWord: false) == ["Galadon"])
    }

    @Test("Below the minimum word length is dropped")
    func minimumLength() {
        let vocab = CompletionVocabulary(contextWords: ["go", "goblin"], minimumWordLength: 3)
        #expect(vocab.completions(forWord: "go", isFirstWord: false) == ["goblin"])
    }

    @Test("Empty / whitespace prefix yields nothing")
    func emptyPrefix() {
        let vocab = CompletionVocabulary(recentWords: ["sword"])
        #expect(vocab.completions(forWord: "", isFirstWord: false).isEmpty)
        #expect(vocab.completions(forWord: "  ", isFirstWord: false).isEmpty)
    }

    @Test("Recent words are gated for very short prefixes; curated sources aren't (#31)")
    func shortPrefixGatesRecent() {
        // The live bug: `say hello :D` breaks on `:`, leaving a 1-char `D` that
        // completed to an arbitrary recent word.
        let noisy = CompletionVocabulary(recentWords: ["Dirt", "Dagger"])
        #expect(noisy.completions(forWord: "D", isFirstWord: false).isEmpty) // 1 char → gated
        #expect(noisy.ghostSuffix(forWord: "D", isFirstWord: false) == nil) // no stray ghost
        // Two chars is enough — recent words contribute again.
        #expect(noisy.completions(forWord: "Di", isFirstWord: false) == ["Dirt"])

        // Curated sources (context, verbs) still complete a 1-char prefix.
        let curated = CompletionVocabulary(contextWords: ["Galadon"], verbs: ["north"])
        #expect(curated.completions(forWord: "G", isFirstWord: false) == ["Galadon"])
        #expect(curated.completions(forWord: "n", isFirstWord: true).contains("north"))
        #expect(curated.ghostSuffix(forWord: "n", isFirstWord: true) == "orth")
    }

    @Test("Verbs rank ahead of recent words (curated before noisy) (#31)")
    func verbsBeforeRecent() {
        let vocab = CompletionVocabulary(recentWords: ["getaway"], verbs: ["get"])
        #expect(vocab.completions(forWord: "ge", isFirstWord: true) == ["get", "getaway"])
    }

    @Test("ghostSuffix is the top completion's tail in its own casing, nil when none")
    func ghostSuffix() {
        let vocab = CompletionVocabulary(contextWords: ["Galadon"], recentWords: ["sword"])
        // Tail of the top match, dropping the typed length (best's casing).
        #expect(vocab.ghostSuffix(forWord: "Gal", isFirstWord: false) == "adon")
        #expect(vocab.ghostSuffix(forWord: "gal", isFirstWord: false) == "adon") // case-insensitive prefix
        // No completion → nil.
        #expect(vocab.ghostSuffix(forWord: "zzz", isFirstWord: false) == nil)
        // An already-complete word has no longer match → nil.
        #expect(vocab.ghostSuffix(forWord: "sword", isFirstWord: false) == nil)
    }
}

@Suite("InputCompletion — word extraction + harvesting")
struct InputCompletionTests {
    @Test("Current word is the run ending at the caret")
    func currentWordAtCaret() {
        let text = "kill Gal"
        let result = InputCompletion.currentWord(in: text, caret: text.count)
        #expect(result?.word == "Gal")
    }

    @Test("Caret after a space → no current word (nothing to complete)")
    func noWordAfterSpace() {
        #expect(InputCompletion.currentWord(in: "kill ", caret: 5) == nil)
    }

    @Test("Completes only the word at the caret, mid-line")
    func midLineCaret() {
        // Caret after "Gal" in "cast 'x' Gal here" → word is "Gal".
        let text = "get Gal bag"
        let result = InputCompletion.currentWord(in: text, caret: 7) // after "get Gal"
        #expect(result?.word == "Gal")
    }

    @Test("Dot is a word break so 2.sword completes sword")
    func dotBreak() {
        let text = "get 2.swo"
        #expect(InputCompletion.currentWord(in: text, caret: text.count)?.word == "swo")
    }

    @Test("Apostrophe stays inside a word")
    func apostropheInWord() {
        let text = "wear mage'"
        #expect(InputCompletion.currentWord(in: text, caret: text.count)?.word == "mage'")
    }

    @Test("First-word detection")
    func firstWord() {
        #expect(InputCompletion.isFirstWord(in: "kil", caret: 3))
        #expect(InputCompletion.isFirstWord(in: "  kil", caret: 5)) // leading space, still first
        #expect(!InputCompletion.isFirstWord(in: "kill ra", caret: 7))
    }

    @Test("Harvest: most-recent first, deduped, min length, split on punctuation")
    func harvest() throws {
        let lines = [
            "A goblin lurks here.", // older
            "Galadon: the goblin square." // newest
        ]
        let words = InputCompletion.harvestWords(from: lines, minLength: 3)
        // Newest line first → "Galadon" leads; "goblin" appears in both lines
        // but dedupes (by lowercase) to its newest occurrence, before "lurks".
        #expect(words.first == "Galadon")
        #expect(words.count(where: { $0.lowercased() == "goblin" }) == 1)
        #expect(try #require(words.firstIndex(of: "goblin")) < words.firstIndex(of: "lurks")!)
        #expect(!words.contains("A")) // length 1, dropped
    }

    @Test("Harvest respects the limit")
    func harvestLimit() {
        let lines = (0..<100).map { "word\($0) extra\($0)" }
        #expect(InputCompletion.harvestWords(from: lines, minLength: 3, limit: 10).count == 10)
    }
}

@testable import MudCore
import Testing

@Suite("CompletionVocabulary — per-verb argument sources (#32)")
struct CompletionArgumentTests {
    private func vocab() -> CompletionVocabulary {
        CompletionVocabulary(
            recentWords: ["wandering"],
            verbs: ["wear", "runto", "cast", "open", "look"],
            argumentSources: [
                .item: ["longsword", "lantern"],
                .area: ["lowlands", "farm"],
                .spell: ["fireball", "frostbolt"],
                .exit: ["north", "south"]
            ]
        )
    }

    @Test("wear completes from the item source")
    func itemArgument() {
        #expect(vocab().ghostSuffix(inLine: "wear lan", caret: 8) == "tern")
    }

    @Test("cast completes from the spell source")
    func spellArgument() {
        #expect(vocab().ghostSuffix(inLine: "cast fro", caret: 8) == "stbolt")
    }

    @Test("open completes from the exit source")
    func exitArgument() {
        #expect(vocab().ghostSuffix(inLine: "open nor", caret: 8) == "th")
    }

    @Test("runto completes from the area source")
    func areaArgument() {
        #expect(vocab().ghostSuffix(inLine: "runto low", caret: 9) == "lands")
    }

    @Test("an unclassified verb's argument falls back to context/recent")
    func fallback() {
        #expect(vocab().ghostSuffix(inLine: "look wan", caret: 8) == "dering")
    }

    @Test("argument-kind table")
    func kindTable() {
        #expect(CommandArguments.argumentKind(verb: "wear", argumentIndex: 0) == .item)
        #expect(CommandArguments.argumentKind(verb: "RUNTO", argumentIndex: 0) == .area)
        #expect(CommandArguments.argumentKind(verb: "xrt", argumentIndex: 0) == .area)
        #expect(CommandArguments.argumentKind(verb: "cast", argumentIndex: 0) == .spell)
        #expect(CommandArguments.argumentKind(verb: "wear", argumentIndex: 1) == nil)
        // `get` is a floor item (→ #32 C tags), not an owned/dinv item.
        #expect(CommandArguments.argumentKind(verb: "get", argumentIndex: 0) == nil)
        #expect(CommandArguments.argumentKind(verb: "score", argumentIndex: 0) == nil)
    }
}

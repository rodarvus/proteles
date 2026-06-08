@testable import MudCore
import Testing

@Suite("CompletionVocabulary — per-verb argument sources (#32)")
struct CompletionArgumentTests {
    private func vocab() -> CompletionVocabulary {
        CompletionVocabulary(
            recentWords: ["wandering"],
            verbs: ["get", "goto", "cast", "open", "look"],
            argumentSources: [
                .item: ["longsword", "lantern"],
                .room: ["recall", "market square"],
                .spell: ["fireball", "frostbolt"],
                .exit: ["north", "south"]
            ]
        )
    }

    @Test("get completes from the item source")
    func itemArgument() {
        #expect(vocab().ghostSuffix(inLine: "get lan", caret: 7) == "tern")
    }

    @Test("cast completes from the spell source")
    func spellArgument() {
        #expect(vocab().ghostSuffix(inLine: "cast fro", caret: 8) == "stbolt")
    }

    @Test("open completes from the exit source")
    func exitArgument() {
        #expect(vocab().ghostSuffix(inLine: "open nor", caret: 8) == "th")
    }

    @Test("an unclassified verb's argument falls back to context/recent")
    func fallback() {
        #expect(vocab().ghostSuffix(inLine: "look wan", caret: 8) == "dering")
    }

    @Test("argument-kind table")
    func kindTable() {
        #expect(CommandArguments.argumentKind(verb: "get", argumentIndex: 0) == .item)
        #expect(CommandArguments.argumentKind(verb: "GOTO", argumentIndex: 0) == .room)
        #expect(CommandArguments.argumentKind(verb: "cast", argumentIndex: 0) == .spell)
        #expect(CommandArguments.argumentKind(verb: "get", argumentIndex: 1) == nil)
        #expect(CommandArguments.argumentKind(verb: "score", argumentIndex: 0) == nil)
    }
}

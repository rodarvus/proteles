@testable import MudCore
import Testing

@Suite("CompletionVocabulary — kind-aware channels + positions (#31)")
struct CompletionChannelTests {
    private func vocab() -> CompletionVocabulary {
        CompletionVocabulary(
            contextWords: ["Galadon", "Tokugawa"],
            recentWords: ["looking", "dragon"],
            verbs: ["gossip", "tell", "north", "get"],
            playerWords: ["Galadon", "Tokugawa"],
            broadcastChannels: ["gossip"],
            directedChannels: ["tell"]
        )
    }

    @Test("verb position completes verbs")
    func verbPosition() {
        #expect(vocab().ghostSuffix(inLine: "gos", caret: 3) == "sip")
    }

    @Test("broadcast channel message suppresses ghosting")
    func broadcastSuppressed() {
        let voc = vocab()
        #expect(voc.completions(inLine: "gossip look", caret: 11).isEmpty)
        #expect(voc.ghostSuffix(inLine: "gossip look", caret: 11) == nil)
    }

    @Test("directed channel completes a player name for the recipient")
    func directedRecipient() {
        #expect(vocab().ghostSuffix(inLine: "tell gal", caret: 8) == "adon")
    }

    @Test("directed channel suppresses ghosting after the recipient")
    func directedMessage() {
        #expect(vocab().completions(inLine: "tell galadon look", caret: 17).isEmpty)
    }

    @Test("regular command argument still completes from context/recent")
    func regularArgument() {
        #expect(vocab().ghostSuffix(inLine: "get dra", caret: 7) == "gon")
    }

    @Test("wordIndex / firstWord track position")
    func positionHelpers() {
        #expect(InputCompletion.wordIndex(in: "tell gal", caret: 8) == 1)
        #expect(InputCompletion.wordIndex(in: "tell galadon lo", caret: 15) == 2)
        #expect(InputCompletion.firstWord(in: "  tell galadon") == "tell")
    }
}

@testable import MudCore
import Testing

@Suite("PluginCommandIndex + subcommand completion (#31)")
struct PluginCommandIndexTests {
    @Test("indexes verbs + subcommands from command-token lists")
    func indexes() {
        let index = PluginCommandIndex(commandTokenLists: [
            ["dinv", "build"], ["dinv", "put"], ["dinv"], ["ldb", "level"], ["ldb"], []
        ])
        #expect(index.verbs == ["dinv", "ldb"])
        #expect(index.subcommands["dinv"] == ["build", "put"])
        #expect(index.subcommands["ldb"] == ["level"])
    }

    @Test("a plugin verb's first argument completes its subcommands")
    func subcommandCompletion() {
        let vocab = CompletionVocabulary(
            verbs: ["dinv"],
            pluginSubcommands: ["dinv": ["build", "put", "refresh"]]
        )
        #expect(vocab.ghostSuffix(inLine: "din", caret: 3) == "v") // verb
        #expect(vocab.ghostSuffix(inLine: "dinv bu", caret: 7) == "ild") // subcommand
        #expect(vocab.ghostSuffix(inLine: "dinv ref", caret: 8) == "resh")
    }
}

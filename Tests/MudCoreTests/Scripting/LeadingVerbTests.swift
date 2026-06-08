@testable import MudCore
import Testing

@Suite("TriggerPattern.commandTokens — verb + subcommand extraction (#31)")
struct CommandTokensTests {
    @Test("plain literals: exact / beginsWith / wildcard")
    func literals() {
        #expect(TriggerPattern.exact("score").commandTokens == ["score"])
        #expect(TriggerPattern.beginsWith("dinv build").commandTokens == ["dinv", "build"])
        #expect(TriggerPattern.wildcard("dinv build *").commandTokens == ["dinv", "build"])
        #expect(TriggerPattern.wildcard("kk *").commandTokens == ["kk"])
        #expect(TriggerPattern.substring("foo").commandTokens.isEmpty)
    }

    @Test("regex aliases — real dinv/leveldb patterns → verb + subcommand")
    func regexPatterns() {
        #expect(TriggerPattern.regex("^[ ]*dinv[ ]+put[ ]+(.*?)[ ]+(.*?)$").commandTokens == ["dinv", "put"])
        #expect(TriggerPattern.regex("^[ ]*dinv[ ]+build[ ]*( confirm|.*)?$").commandTokens == [
            "dinv",
            "build"
        ])
        #expect(TriggerPattern.regex("^[ ]*dinv[ ]+refresh[ ]*(on|eager)[ ]*([0-9]+)?$").commandTokens == [
            "dinv",
            "refresh"
        ])
        #expect(TriggerPattern.regex("^ldb level(?: (\\d+))?(?: (.+))?$").commandTokens == ["ldb", "level"])
        #expect(TriggerPattern.regex("^ldb$").commandTokens == ["ldb"])
        #expect(TriggerPattern.regex("^ldb help$").commandTokens == ["ldb", "help"])
        #expect(TriggerPattern.regex("^\\s*xrt\\s+(.+)$").commandTokens == ["xrt"])
    }

    @Test("leadingVerb = first token (regex now contributes, lowercased)")
    func leadingVerb() {
        #expect(TriggerPattern.regex("^kk").leadingVerb == "kk")
        #expect(TriggerPattern.exact("KK").leadingVerb == "kk")
        #expect(TriggerPattern.substring("foo").leadingVerb == nil)
    }
}

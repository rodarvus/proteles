import Foundation
@testable import MudCore
import Testing

@Suite("CommandStack — client-side ;-stacking")
struct CommandStackTests {
    @Test("Plain text with no separator is one command")
    func noSeparator() {
        #expect(CommandStack.split("look") == ["look"])
        #expect(CommandStack.split("open south") == ["open south"])
    }

    @Test("Single semicolons split into separate commands")
    func splitsOnSeparator() {
        #expect(CommandStack.split("n;s;e") == ["n", "s", "e"])
        #expect(CommandStack.split("open south;s") == ["open south", "s"])
    }

    @Test("A doubled ;; is an escaped literal ; and does not split")
    func doubledIsLiteral() {
        #expect(CommandStack.split("say hi;;there") == ["say hi;there"])
        #expect(CommandStack.split("open south;;s") == ["open south;s"])
    }

    @Test("A ;; followed by a real ; yields a literal then a split")
    func literalThenSplit() {
        #expect(CommandStack.split("n;;;s") == ["n;", "s"])
    }

    @Test("Empty input is preserved as one empty command (bare-Enter nudge)")
    func emptyPreserved() {
        #expect(CommandStack.split("") == [""])
    }

    @Test("A trailing separator yields a trailing empty piece")
    func trailingSeparator() {
        #expect(CommandStack.split("n;") == ["n", ""])
    }

    @Test("A leading separator yields a leading empty piece")
    func leadingSeparator() {
        #expect(CommandStack.split(";n") == ["", "n"])
    }

    @Test("A custom separator is honoured")
    func customSeparator() {
        #expect(CommandStack.split("n|s|e", separator: "|") == ["n", "s", "e"])
    }
}

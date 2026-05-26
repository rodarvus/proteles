@testable import MudCore
import Testing

@Suite("SessionController — omit blank lines")
struct SessionControllerOmitBlankLinesTests {
    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    @Test("A completely empty line is omitted only when the preference is on")
    func emptyLineOmittedWhenEnabled() {
        #expect(SessionController.omitsFromOutput(line(""), omitBlankLines: true))
        #expect(!SessionController.omitsFromOutput(line(""), omitBlankLines: false))
    }

    @Test("Whitespace-only lines are kept (matches the reference's ^$)")
    func whitespaceOnlyKept() {
        #expect(!SessionController.omitsFromOutput(line("   "), omitBlankLines: true))
        #expect(!SessionController.omitsFromOutput(line("\t"), omitBlankLines: true))
    }

    @Test("Non-empty lines are never omitted")
    func nonEmptyKept() {
        #expect(!SessionController.omitsFromOutput(line("You see a goblin."), omitBlankLines: true))
    }
}

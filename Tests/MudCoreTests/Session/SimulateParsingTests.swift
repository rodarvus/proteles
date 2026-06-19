import Foundation
@testable import MudCore
import Testing

/// `Simulate(...)` / `reinjectSimulated` must parse its text the same way real
/// inbound MUD bytes are parsed (ANSIParser → LineBuilder): embedded ANSI codes
/// become styled runs (so the line renders in colour) and `Line.text` is the
/// stripped text (so triggers match what the MUD would show) — not a raw line
/// carrying literal escape codes (the pre-fix behaviour the user saw on screen).
@Suite("Simulate — inbound ANSI parsing")
struct SimulateParsingTests {
    private let esc = "\u{1B}"

    @Test("ANSI codes become a styled run; Line.text is stripped")
    func parsesAnsiToStyledStrippedLine() {
        let lines = SessionController.simulatedLines(from: "\(esc)[1;31mRed\(esc)[0m")
        #expect(lines.count == 1)
        #expect(lines.first?.text == "Red") // escape codes stripped from visible text
        #expect(lines.first?.runs.isEmpty == false) // colour captured as a styled run
        #expect(lines.first?.runs.first?.style.foreground != nil) // a real colour, not default
    }

    @Test("plain text is one stripped line with no runs")
    func plainText() {
        let lines = SessionController.simulatedLines(from: "You feel hungry.")
        #expect(lines.map(\.text) == ["You feel hungry."])
        #expect(lines.first?.runs.isEmpty == true)
    }

    @Test("newlines split into lines; a lone trailing newline adds no empty line")
    func newlineHandling() {
        #expect(SessionController.simulatedLines(from: "a\nb").map(\.text) == ["a", "b"])
        #expect(SessionController.simulatedLines(from: "a\n").map(\.text) == ["a"])
        // A blank middle line is preserved (matches the live pipeline).
        #expect(SessionController.simulatedLines(from: "a\n\nb").map(\.text) == ["a", "", "b"])
    }
}

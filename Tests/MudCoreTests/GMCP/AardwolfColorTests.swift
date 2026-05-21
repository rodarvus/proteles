import Foundation
@testable import MudCore
import Testing

@Suite("AardwolfColor — @-code parsing")
struct AardwolfColorTests {
    @Test("Plain text has no codes and no runs")
    func plainText() {
        let line = AardwolfColor.styledLine(from: "hello world")
        #expect(line.text == "hello world")
        #expect(line.runs.isEmpty)
    }

    @Test("@@ becomes a literal @")
    func escapedAt() {
        let line = AardwolfColor.styledLine(from: "user@@host")
        #expect(line.text == "user@host")
        #expect(line.runs.isEmpty)
    }

    @Test("A normal colour code styles the following text")
    func normalColour() {
        let line = AardwolfColor.styledLine(from: "@rdanger")
        #expect(line.text == "danger")
        #expect(line.runs == [
            StyledRun(utf16Range: 0..<6, style: StyleAttributes(foreground: .named(.red)))
        ])
    }

    @Test("An uppercase code is a bright colour")
    func brightColour() {
        let line = AardwolfColor.styledLine(from: "@Gok")
        #expect(line.text == "ok")
        #expect(line.runs.first?.style.foreground == .brightNamed(.green))
    }

    @Test("@xNNN selects an xterm palette colour")
    func xtermColour() {
        let line = AardwolfColor.styledLine(from: "@x214amber")
        #expect(line.text == "amber")
        #expect(line.runs.first?.style.foreground == .palette(214))
    }

    @Test("xterm values above 255 clamp")
    func xtermClamps() {
        let line = AardwolfColor.styledLine(from: "@x999x")
        #expect(line.runs.first?.style.foreground == .palette(255))
    }

    @Test("Colour changes split into separate runs")
    func multipleRuns() {
        let line = AardwolfColor.styledLine(from: "@rred@g" + "green")
        #expect(line.text == "redgreen")
        #expect(line.runs == [
            StyledRun(utf16Range: 0..<3, style: StyleAttributes(foreground: .named(.red))),
            StyledRun(utf16Range: 3..<8, style: StyleAttributes(foreground: .named(.green)))
        ])
    }

    @Test("Unknown @-codes are dropped")
    func unknownCodeDropped() {
        let line = AardwolfColor.styledLine(from: "a@!b")
        #expect(line.text == "ab")
        #expect(line.runs.isEmpty)
    }

    @Test("A lone trailing @ is dropped")
    func loneTrailingAt() {
        let line = AardwolfColor.styledLine(from: "done@")
        #expect(line.text == "done")
    }

    @Test("Real Aardwolf channel message strips to clean text with runs")
    func realChannelMessage() {
        // Verbatim from a captured comm.channel payload.
        let coded = "@GCLAN: Rodarvus, defender of the just, must now leave us.@w"
        let line = AardwolfColor.styledLine(from: coded)
        #expect(line.text == "CLAN: Rodarvus, defender of the just, must now leave us.")
        #expect(line.runs.first?.style.foreground == .brightNamed(.green))
        #expect(AardwolfColor.stripped(coded) == line.text)
    }
}

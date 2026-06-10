@testable import MudCore
import Testing

/// ``AardwolfTags/displayLine(for:)`` — the display transform behind "Clean
/// Aardwolf tag markers". Cases drawn verbatim from live session recordings
/// (2026-06-10). The old behaviour withheld the whole line, which deleted
/// real content (with `tags rname on`, the room name only arrives inside
/// the tag line).
@Suite("Aardwolf tag stripping — markers go, content stays")
struct AardwolfTagStripTests {
    private func display(_ text: String, runs: [StyledRun] = []) -> Line? {
        AardwolfTags.displayLine(for: Line(id: LineID(1), text: text, runs: runs))
    }

    @Test("content tags show their content, marker stripped")
    func contentShows() {
        #expect(display("{rname}The top of the tower")?.text == "The top of the tower")
        #expect(display("{rname}In the clouds (G) (2608)")?.text == "In the clouds (G) (2608)")
        #expect(display("{exits}[ Exits: north south west ]")?.text == "[ Exits: north south west ]")
        // Arg-carrying markers strip too ({chan ch=…} wraps real chat).
        #expect(display("{chan ch=tech}[Tech] Bob: hi")?.text == "[Tech] Bob: hi")
    }

    @Test("machine-data tags hide entirely — their content is CSV noise")
    func machineDataHides() {
        #expect(display("{coords}4,6,20") == nil) // the user-confirmed exception
        #expect(display("{invmon}1,3718207015,-1,31") == nil)
        #expect(display("{invdata}") == nil)
        #expect(display("{invdata 3629436877}") == nil)
        #expect(display("{affon}97,1800") == nil)
        #expect(display("{affoff}97") == nil)
        #expect(display("{skillgain}253,100") == nil)
        #expect(display("{sfail}58,0,2,-1") == nil)
        #expect(display("{recon}2,398") == nil)
    }

    @Test("marker-only lines (open and close) hide — nothing left to show")
    func bareMarkersHide() {
        #expect(display("{roomobjs}") == nil)
        #expect(display("{/roomobjs}") == nil)
        #expect(display("{roomchars}") == nil)
        #expect(display("{spellheaders hsp}") == nil)
        #expect(display("{/spellheaders}") == nil)
        #expect(display("{/rdesc}") == nil)
    }

    @Test("non-tag lines pass through untouched")
    func proseUntouched() {
        #expect(display("A goblin arrives from the north.")?.text
            == "A goblin arrives from the north.")
        #expect(display("{ DINV fence 16 }")?.text == "{ DINV fence 16 }")
        #expect(display("You found a {special} item.")?.text == "You found a {special} item.")
    }

    @Test("stripping shifts styled runs and keeps links on the content")
    func runsShift() throws {
        let link = LineLink(action: .sendCommand("north"))
        let text = "{exits}[ Exits: north ]"
        let line = Line(id: LineID(1), text: text, runs: [
            // The marker span (dim) + the content span (green, linked).
            StyledRun(utf16Range: 0..<7, style: StyleAttributes(dim: true)),
            StyledRun(
                utf16Range: 7..<23,
                style: StyleAttributes(foreground: .named(.green)),
                link: link
            )
        ])
        let stripped = try #require(AardwolfTags.displayLine(for: line))
        #expect(stripped.text == "[ Exits: north ]")
        #expect(stripped.runs == [
            StyledRun(
                utf16Range: 0..<16,
                style: StyleAttributes(foreground: .named(.green)),
                link: link
            )
        ])
    }

    @Test("the detector accepts arg-carrying tags it previously missed")
    func detectorArgTags() {
        #expect(SessionController.isAardwolfTagLine("{invdata 3629436877}"))
        #expect(SessionController.isAardwolfTagLine("{chan ch=tech}[Tech] hi"))
        #expect(SessionController.isAardwolfTagLine("{spellheaders hsp}"))
        // Still rejects non-tags.
        #expect(!SessionController.isAardwolfTagLine("{ DINV fence 16 }"))
        #expect(!SessionController.isAardwolfTagLine("{rname")) // unterminated
    }
}

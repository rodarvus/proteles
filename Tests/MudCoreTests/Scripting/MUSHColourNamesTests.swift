@testable import MudCore
import Testing

/// `ColourNameToRGB` / `RGBColourToName` — verified against MUSHclient's own
/// values (`MXP_colours[]` + `SetColour`/`ColourToName`). The integers are
/// COLORREFs (red in the low byte), matching ``MUSHColour/int(for:)``.
@Suite("MUSHColour — named-colour <-> RGB")
struct MUSHColourNamesTests {
    @Test("named colours resolve to MUSHclient's COLORREF values")
    func nameToRGB() {
        #expect(MUSHColour.colourNameToRGB("red") == 0x0000FF) // 255
        #expect(MUSHColour.colourNameToRGB("blue") == 0xFF0000)
        #expect(MUSHColour.colourNameToRGB("white") == 0xFFFFFF)
        #expect(MUSHColour.colourNameToRGB("black") == 0x000000)
        #expect(MUSHColour.colourNameToRGB("gold") == 0x00D7FF)
        // lime (the ANSI bright green) and green (the darker W3C green) differ.
        #expect(MUSHColour.colourNameToRGB("lime") == 0x00FF00)
        #expect(MUSHColour.colourNameToRGB("green") == 0x008000)
    }

    @Test("the COLORREF agrees with the existing 16-colour palette")
    func agreesWithPalette() {
        // GetBoldColour(1) is bright red; GetNormalColour(2) is dim green.
        #expect(MUSHColour.colourNameToRGB("red") == MUSHColour.bold[1])
        #expect(MUSHColour.colourNameToRGB("blue") == MUSHColour.bold[4])
        #expect(MUSHColour.colourNameToRGB("white") == MUSHColour.bold[7])
    }

    @Test("name lookup trims, lowercases, and rejects the unknown")
    func nameNormalisation() {
        #expect(MUSHColour.colourNameToRGB("RED") == 0x0000FF)
        #expect(MUSHColour.colourNameToRGB("  Red  ") == 0x0000FF)
        #expect(MUSHColour.colourNameToRGB("notacolour") == -1)
        #expect(MUSHColour.colourNameToRGB("") == -1)
    }

    @Test("#rrggbb literals parse like SetColour (and equal the named value)")
    func hexLiterals() {
        #expect(MUSHColour.colourNameToRGB("#ff0000") == MUSHColour.colourNameToRGB("red"))
        #expect(MUSHColour.colourNameToRGB("#0000ff") == MUSHColour.colourNameToRGB("blue"))
        #expect(MUSHColour.colourNameToRGB("#ffffff") == 0xFFFFFF)
        #expect(MUSHColour.colourNameToRGB("#") == 0x000000) // black, as SetColour
        #expect(MUSHColour.colourNameToRGB("#1234567") == -1) // too long
    }

    @Test("RGBColourToName reverses, and is deterministic on aliases")
    func rgbToName() {
        #expect(MUSHColour.rgbColourToName(0x0000FF) == "red")
        #expect(MUSHColour.rgbColourToName(0xFF0000) == "blue")
        #expect(MUSHColour.rgbColourToName(0xFFFFFF) == "white")
        #expect(MUSHColour.rgbColourToName(0x000000) == "black")
        // aqua/cyan share a value; aqua is first in source order.
        #expect(MUSHColour.rgbColourToName(MUSHColour.colourNameToRGB("aqua")) == "aqua")
        // gray/grey share a value; gray is first.
        #expect(MUSHColour.rgbColourToName(MUSHColour.colourNameToRGB("gray")) == "gray")
        // no name → #RRGGBB
        #expect(MUSHColour.rgbColourToName(0x010203) == "#030201")
    }

    @Test("every named colour round-trips through both functions")
    func roundTrip() {
        for entry in MUSHColour.names {
            let rgb = MUSHColour.colourNameToRGB(entry.name)
            #expect(rgb >= 0, "\(entry.name) failed to resolve")
            // Round-trips to *a* name sharing the same value (alias-safe).
            let back = MUSHColour.rgbColourToName(rgb)
            #expect(MUSHColour.colourNameToRGB(back) == rgb, "\(entry.name) -> \(rgb) -> \(back)")
        }
        // A #hex with no named match round-trips to the same literal.
        let hex = MUSHColour.colourNameToRGB("#123456")
        #expect(MUSHColour.rgbColourToName(hex) == "#123456")
    }
}

/// The same two functions reached through the generic compat shim (the path a
/// real plugin uses), to prove the host-function wiring is live.
@Suite("MUSHColour — ColourNameToRGB/RGBColourToName via the shim")
struct MUSHColourShimTests {
    @Test("the shim globals delegate to the native table")
    func shimGlobals() async throws {
        let engine = try ScriptEngine()
        try await engine.loadCompatShim()
        #expect(await engine.evaluateConsole("ColourNameToRGB('red')")
            == [.note(text: "lua: = 255", foreground: "cyan", background: nil)])
        #expect(await engine.evaluateConsole("RGBColourToName(255)")
            == [.note(text: "lua: = red", foreground: "cyan", background: nil)])
        #expect(await engine.evaluateConsole("RGBColourToName(ColourNameToRGB('cornflowerblue'))")
            == [.note(text: "lua: = cornflowerblue", foreground: "cyan", background: nil)])
    }
}

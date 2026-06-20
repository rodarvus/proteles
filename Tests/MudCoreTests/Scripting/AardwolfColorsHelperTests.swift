import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — aardwolf_colors + native @-code output")
struct AardwolfColorsHelperTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("strip_colours removes @-codes, keeping @@ and @- literals")
    func stripColours() async throws {
        let lua = try await shimmed()
        try await lua.run("require 'aardwolf_colors'")
        #expect(try await lua.string("strip_colours('@rred@@ @x123x @gtext@-')") == "red@ x text~")
    }

    @Test("ColoursToANSI emits SGR sequences around the text")
    func coloursToANSI() async throws {
        let lua = try await shimmed()
        try await lua.run("require 'aardwolf_colors'")
        // ESC[0;31m red ESC[0;32m green ESC[0m   (ESC == \\27)
        let ansi = try await lua.string("ColoursToANSI('@rred@ggreen')")
        let esc = "\u{1b}"
        #expect(ansi == "\(esc)[0;31mred\(esc)[0;32mgreen\(esc)[0m")
    }

    @Test("ColoursToStyles → StylesToColours round-trips basic colours")
    func stylesRoundTrip() async throws {
        let lua = try await shimmed()
        try await lua.run("require 'aardwolf_colors'")
        // A styles run carries text/length/colour/bold; re-serialising yields
        // the same @-coded string.
        #expect(try await lua.string("StylesToColours(ColoursToStyles('@rred@Ggreen'))") == "@rred@Ggreen")
        #expect(try await lua.number("#ColoursToStyles('@rred@Ggreen')") == 2)
        #expect(try await lua.boolean("ColoursToStyles('@Rx')[1].bold == true"))
    }

    @Test("StylesToColoursOneLine with no range == StylesToColours (rsocial path)")
    func stylesToColoursOneLineWhole() async throws {
        let lua = try await shimmed()
        try await lua.run("require 'aardwolf_colors'")
        let whole = try await lua.string("StylesToColoursOneLine(ColoursToStyles('@rred@Ggreen'))")
        #expect(whole == "@rred@Ggreen")
    }

    @Test("StylesToColoursOneLine truncates to a column range (mudbin path)")
    func stylesToColoursOneLineTruncated() async throws {
        let lua = try await shimmed()
        try await lua.run("require 'aardwolf_colors'")
        // "redgreen" cols 2..6 = "edgre" → "ed"(red) + "gre"(green) → @-coded.
        let cut = try await lua.string("StylesToColoursOneLine(ColoursToStyles('@rred@Ggreen'), 2, 6)")
        #expect(cut == "@red@Ggre")
    }

    @Test("proteles.echoAard renders @-codes as a styled echo")
    func echoAardNative() async throws {
        let lua = try LuaRuntime()
        let effects = try await lua.run("proteles.echoAard('@rhello')")
        #expect(effects == [.echoAard("@rhello")])
    }

    @Test("The host renders ANSI text into a styled Line")
    func ansiLineRendersRuns() {
        let esc = "\u{1b}"
        let line = SessionController.ansiLine("\(esc)[31mred\(esc)[0m plain")
        #expect(line.text == "red plain")
        // The coloured "red" produced a styled run; "plain" is default (no run).
        #expect(line.runs.count == 1)
        #expect(line.runs.first?.utf16Range == 0..<3)
    }

    @Test("AnsiNote renders ANSI text (the AnsiNote(ColoursToANSI(...)) path)")
    func ansiNote() async throws {
        let lua = try await shimmed()
        try await lua.run("require 'aardwolf_colors'")
        let effects = try await lua.run("AnsiNote(ColoursToANSI('@rhi'))")
        let esc = "\u{1b}"
        #expect(effects == [.echoAnsi("\(esc)[0;31mhi\(esc)[0m")])
    }
}

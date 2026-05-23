import Foundation
@testable import MudCore
import Testing

@Suite("AsciiMap — capture <MAPSTART>…<MAPEND>")
struct AsciiMapTests {
    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    @Test("Captures the block, gags it, and emits the map on MAPEND")
    func captureBlock() {
        var plugin = AsciiMap()
        // Lines before the map pass through untouched.
        #expect(plugin.onLine(line("You are here.")).gag == false)

        #expect(plugin.onLine(line("<MAPSTART>")).gag == true)
        #expect(plugin.onLine(line("[ ][ ]")).gag == true) // body gagged
        #expect(plugin.onLine(line(" | ")).gag == true)

        let end = plugin.onLine(line("<MAPEND>"))
        #expect(end.gag == true)
        guard case .updateMap(let lines)? = end.effects.first else {
            Issue.record("expected an updateMap effect"); return
        }
        #expect(lines.map(\.text) == ["[ ][ ]", " | "])
    }

    @Test("After the block ends, normal lines pass through again")
    func resumesAfterBlock() {
        var plugin = AsciiMap()
        _ = plugin.onLine(line("<MAPSTART>"))
        _ = plugin.onLine(line("body"))
        _ = plugin.onLine(line("<MAPEND>"))
        #expect(plugin.onLine(line("A goblin arrives.")).gag == false)
    }

    @Test("connect enables the map telnet-option but sends NO game command")
    func connectEnablesMap() {
        let plugin = AsciiMap()
        let effects = plugin.connect()
        #expect(effects == [.aardwolfTelnet(option: 4, on: true)])
        // Crucially, no `map` (or any) command pre-login — that would break
        // auto-login by being consumed as the name/password.
        #expect(!effects.contains(.send("map")))
    }

    @Test("room.info refreshes the map only while in a playing state")
    func refreshGatedOnState() {
        var plugin = AsciiMap()
        // Before any playing-state status: room.info must NOT send `map`
        // (this is what would corrupt auto-login / a note).
        #expect(plugin.onGMCP(package: "room.info", json: "{}").isEmpty)

        // Enter a playing state (3) → entering fires an initial map request.
        #expect(plugin.onGMCP(package: "char.status", json: #"{"state":3}"#) == [.send("map")])
        // Now room.info refreshes.
        #expect(plugin.onGMCP(package: "room.info", json: "{}") == [.send("map")])

        // Non-map packages are ignored.
        #expect(plugin.onGMCP(package: "char.vitals", json: "{}").isEmpty)
    }

    @Test("Login (state 1) and note-writing (state 5) never trigger a map request")
    func unsafeStatesBlocked() {
        var plugin = AsciiMap()
        // Login state — no request, and room.info stays silent.
        #expect(plugin.onGMCP(package: "char.status", json: #"{"state":1}"#).isEmpty)
        #expect(plugin.onGMCP(package: "room.info", json: "{}").isEmpty)

        // Enter play (3), then start a note (5): room.info must not send `map`
        // (it would be typed into the note).
        _ = plugin.onGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(plugin.onGMCP(package: "char.status", json: #"{"state":5}"#).isEmpty)
        #expect(plugin.onGMCP(package: "room.info", json: "{}").isEmpty)
    }

    @Test("Entering a playing state requests a map only on the transition")
    func requestsOnceOnTransition() {
        var plugin = AsciiMap()
        #expect(plugin.onGMCP(package: "char.status", json: #"{"state":3}"#) == [.send("map")])
        // Staying in state 3 (e.g. align update) must not re-request.
        #expect(plugin.onGMCP(package: "char.status", json: #"{"state":3}"#).isEmpty)
    }

    @Test("Aardwolf telnet framing is IAC SB 102 <opt> <1|2> IAC SE")
    func telnetFraming() {
        #expect(SessionController.aardwolfTelnetBytes(option: 4, on: true)
            == [0xFF, 0xFA, 102, 4, 1, 0xFF, 0xF0])
        #expect(SessionController.aardwolfTelnetBytes(option: 18, on: false)
            == [0xFF, 0xFA, 102, 18, 2, 0xFF, 0xF0])
    }
}

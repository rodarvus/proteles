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

    @Test("room.info triggers a map refresh (the post-login request)")
    func refreshesOnRoomChange() {
        var plugin = AsciiMap()
        #expect(plugin.onGMCP(package: "room.info", json: "{}") == [.send("map")])
        #expect(plugin.onGMCP(package: "char.vitals", json: "{}").isEmpty)
    }

    @Test("Aardwolf telnet framing is IAC SB 102 <opt> <1|2> IAC SE")
    func telnetFraming() {
        #expect(SessionController.aardwolfTelnetBytes(option: 4, on: true)
            == [0xFF, 0xFA, 102, 4, 1, 0xFF, 0xF0])
        #expect(SessionController.aardwolfTelnetBytes(option: 18, on: false)
            == [0xFF, 0xFA, 102, 18, 2, 0xFF, 0xF0])
    }
}

import Foundation
@testable import MudCore
import Testing

/// The native continent-bigmap capture (the reference
/// `Aardwolf_Bigmap_Graphical` behaviour): request `bigmap noself` once per
/// continent per session, swallow + border-strip that response, and leave a
/// user-typed `bigmap` visible (markers hidden).
@Suite("ContinentBigmap — capture + request gating")
struct ContinentBigmapTests {
    private func line(_ text: String, runs: [StyledRun] = []) -> Line {
        Line(id: LineID(0), text: text, runs: runs)
    }

    /// Drive the plugin into the playing state and onto a continent, so a
    /// request fires. Returns the effects of the room.info.
    private func enterContinent(_ plugin: inout ContinentBigmap, zone: Int = 1) -> [ScriptEffect] {
        _ = plugin.onGMCP(package: "char.status", json: #"{"state": 3}"#)
        return plugin.onGMCP(
            package: "room.info",
            json: #"{"num":-1,"name":"On the Continent","coord":{"id":\#(zone),"x":5,"y":2,"cont":1}}"#
        )
    }

    @Test("entering a continent requests the bigmap — once per zone per session")
    func requestsOnce() {
        var plugin = ContinentBigmap()
        #expect(enterContinent(&plugin) == [.send("bigmap noself")])
        // Moving within the continent: no re-request.
        #expect(enterContinent(&plugin).isEmpty)
        // A different continent fetches its own map.
        #expect(enterContinent(&plugin, zone: 2) == [.send("bigmap noself")])
    }

    @Test("no request while not in a playing state, or off-continent")
    func requestGating() {
        var plugin = ContinentBigmap()
        // state 1 = login: never inject a command.
        _ = plugin.onGMCP(package: "char.status", json: #"{"state": 1}"#)
        let effects = plugin.onGMCP(
            package: "room.info",
            json: #"{"num":-1,"name":"X","coord":{"id":1,"x":0,"y":0,"cont":1}}"#
        )
        #expect(effects.isEmpty)
        // Playing but in a normal area room (cont 0): nothing.
        _ = plugin.onGMCP(package: "char.status", json: #"{"state": 3}"#)
        let area = plugin.onGMCP(
            package: "room.info",
            json: #"{"num":123,"name":"An Inn","coord":{"id":4,"x":3,"y":4,"cont":0}}"#
        )
        #expect(area.isEmpty)
    }

    @Test("a requested bigmap is swallowed, border-stripped, and published")
    func capturesRequestedMap() {
        var plugin = ContinentBigmap()
        #expect(enterContinent(&plugin) == [.send("bigmap noself")])

        #expect(plugin.onLine(line("{bigmap}1,Mesolar")).gag == true)
        #expect(plugin.onLine(line("+------+")).gag == true)
        let row = line(
            "|~~^^..|",
            runs: [StyledRun(utf16Range: 0..<8, style: StyleAttributes(foreground: .palette(4)))]
        )
        #expect(plugin.onLine(row).gag == true)
        #expect(plugin.onLine(line("|~?~~..|")).gag == true)
        #expect(plugin.onLine(line("+------+")).gag == true)
        let end = plugin.onLine(line("{/bigmap}"))
        #expect(end.gag == true)

        guard case .updateBigmap(let zone, let name, let lines) = end.effects.first else {
            Issue.record("expected updateBigmap, got \(end.effects)")
            return
        }
        #expect(zone == 1)
        #expect(name == "Mesolar")
        // First/last rows dropped; each remaining row loses its | frame.
        #expect(lines.map(\.text) == ["~~^^..", "~?~~.."])
        // Style runs re-clip to the trimmed span (shifted one left).
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 0..<6, style: StyleAttributes(foreground: .palette(4)))
        ])
    }

    @Test("a user-typed bigmap stays visible — only the markers hide")
    func userBigmapVisible() {
        var plugin = ContinentBigmap()
        // No request outstanding: markers gag, the map itself displays.
        #expect(plugin.onLine(line("{bigmap}1,Mesolar")).gag == true)
        let body = plugin.onLine(line("|~~^^..|"))
        #expect(body.gag == false)
        #expect(body.effects.isEmpty)
        let end = plugin.onLine(line("{/bigmap}"))
        #expect(end.gag == true)
        #expect(end.effects.isEmpty)
    }

    @Test("connect enables the BIGMAP telnet option (2)")
    func connectOption() {
        let plugin = ContinentBigmap()
        #expect(plugin.connect() == [.aardwolfTelnet(option: 2, on: true)])
    }
}

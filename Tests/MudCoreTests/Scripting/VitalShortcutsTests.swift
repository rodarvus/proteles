import Foundation
@testable import MudCore
import Testing

@Suite("VitalShortcuts — native vitals commands")
struct VitalShortcutsTests {
    /// A plugin primed with the player's name + vitals (hp 80, mana 40,
    /// moves 100 out of 100 each).
    private func primed() -> VitalShortcuts {
        var plugin = VitalShortcuts()
        _ = plugin.onGMCP(package: "char.base", json: #"{"name":"Tester"}"#)
        _ = plugin.onGMCP(package: "char.vitals", json: #"{"hp":80,"mana":40,"moves":100}"#)
        _ = plugin.onGMCP(
            package: "char.maxstats",
            json: #"{"maxhp":100,"maxmana":100,"maxmoves":100}"#
        )
        return plugin
    }

    /// Extract the segments of the single colourNote effect (else nil).
    private func segments(_ effects: [ScriptEffect]?) -> [NoteSegment]? {
        guard let effects, effects.count == 1, case .colourNote(let segs) = effects[0] else { return nil }
        return segs
    }

    @Test("`hp` prints your hitpoint percentage, coloured green when healthy")
    func ownHitpoints() {
        let plugin = primed()
        let segs = segments(plugin.handleCommand("hp"))
        #expect(segs?.map(\.text) == ["Hitpoints: ", "80", "%"])
        // 80% → green (#90EE90); label/percent-sign in silver.
        #expect(segs?[1].foreground == "#90EE90")
        #expect(segs?[0].foreground == "#C0C0C0")
    }

    @Test("Thresholds: <=66 yellow, <=33 red")
    func thresholds() {
        let plugin = primed()
        #expect(segments(plugin.handleCommand("mn"))?[1].foreground == "#FFFF40") // 40% mana → yellow
        var low = VitalShortcuts()
        _ = low.onGMCP(package: "char.vitals", json: #"{"hp":20,"mana":0,"moves":0}"#)
        _ = low.onGMCP(package: "char.maxstats", json: #"{"maxhp":100,"maxmana":100,"maxmoves":100}"#)
        #expect(segments(low.handleCommand("hp"))?[1].foreground == "#FF4040") // 20% → red
    }

    @Test("Aliases hit/mana/moves map to the same stats as hp/mn/mv")
    func aliases() {
        let plugin = primed()
        #expect(segments(plugin.handleCommand("hit"))?.map(\.text) == ["Hitpoints: ", "80", "%"])
        #expect(segments(plugin.handleCommand("moves"))?.map(\.text) == ["Moves: ", "100", "%"])
    }

    @Test("`vitals` prints all three stats")
    func allVitals() {
        let plugin = primed()
        guard let effects = plugin.handleCommand("vitals") else {
            Issue.record("vitals not handled"); return
        }
        #expect(effects.count == 3)
    }

    @Test("Unrelated input is not handled (passes through to the MUD)")
    func passthrough() {
        let plugin = primed()
        #expect(plugin.handleCommand("look") == nil)
        #expect(plugin.handleCommand("kill mob") == nil)
    }

    @Test("`hp below N` reports you when under the threshold, else a notice")
    func ownBelow() {
        let plugin = primed()
        // 80% < 90 → reported.
        #expect(segments(plugin.handleCommand("hp below 90"))?.map(\.text) == ["Hitpoints: ", "80", "%"])
        // 80% < 50 → false → "no one found" notice.
        let notice = segments(plugin.handleCommand("hp below 50"))
        #expect(notice?.count == 1)
        #expect(notice?[0].text.contains("No one found") == true)
    }

    @Test("A grouped member's stat is shown by name prefix")
    func groupedMember() {
        var plugin = primed()
        _ = plugin.onGMCP(package: "group", json: """
        {"groupname":"G","members":[
          {"name":"Fiendish","info":{"hp":"30","mhp":"100","mn":"50","mmn":"100","mv":"90","mmv":"100"}}
        ]}
        """)
        let segs = segments(plugin.handleCommand("hp fien"))
        #expect(segs?.map(\.text) == ["Fiendish hitpoints: ", "30", "%"])
        #expect(segs?[1].foreground == "#FF4040") // 30% → red
    }

    @Test("`vitals below N` scans the whole group")
    func groupBelow() {
        var plugin = primed()
        _ = plugin.onGMCP(package: "group", json: """
        {"groupname":"G","members":[
          {"name":"Alpha","info":{"hp":"10","mhp":"100","mn":"10","mmn":"100","mv":"10","mmv":"100"}},
          {"name":"Beta","info":{"hp":"90","mhp":"100","mn":"90","mmn":"100","mv":"90","mmv":"100"}}
        ]}
        """)
        // Below 50: Alpha's hp/mn/mv (3) only.
        let effects = plugin.handleCommand("vitals below 50")
        #expect(effects?.count == 3)
    }

    @Test("During note-writing (state 5) the command passes through")
    func noteMode() {
        var plugin = primed()
        _ = plugin.onGMCP(package: "char.status", json: #"{"state":5,"level":1}"#)
        #expect(plugin.handleCommand("hp") == nil)
        // Leaving note mode restores handling.
        _ = plugin.onGMCP(package: "char.status", json: #"{"state":3,"level":1}"#)
        #expect(plugin.handleCommand("hp") != nil)
    }

    @Test("`vitals help` returns a multi-line cheat-sheet")
    func help() {
        let plugin = VitalShortcuts()
        let effects = plugin.handleCommand("vitals help")
        #expect((effects?.count ?? 0) > 3)
    }

    @Test("Missing GMCP data yields a graceful 'not available' line")
    func missingData() {
        let plugin = VitalShortcuts() // nothing primed
        let segs = segments(plugin.handleCommand("hp"))
        #expect(segs?[0].text.contains("not available") == true)
    }
}

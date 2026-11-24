import Foundation
@testable import MudCore
import Testing

/// The Consider feature as the state model's consumer (S0b item 2, #84;
/// `docs/plans/S0B_ITEM2_PROPOSAL.md` Q3, Q4).
@Suite("ConsiderFeature")
struct ConsiderFeatureTests {
    private let considerAll = ScriptEffect.sendNoEcho("consider all")

    /// A feature in a playing state (state 3), standing in room 1 of `aylor`,
    /// in auto mode `auto`.
    private func playingFeature(_ auto: ConsiderAutoMode = .off) -> ConsiderFeature {
        var feature = ConsiderFeature()
        _ = feature.handleCommand("conw \(auto.rawValue)")
        _ = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":3,"align":500}"#)
        _ = feature.onGMCP(package: "room.info", json: #"{"num":1,"name":"r","zone":"aylor","details":""}"#)
        // Close the consider that entering the room sent in auto mode.
        _ = feature.onLine(line(ConsiderFeature.endSentinel))
        return feature
    }

    private func enter(
        _ feature: inout ConsiderFeature,
        room: Int,
        zone: String = "aylor"
    ) -> [ScriptEffect] {
        feature.onGMCP(
            package: "room.info",
            json: #"{"num":\#(room),"name":"r","zone":"\#(zone)","details":""}"#
        )
    }

    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    private func snapshot(_ effects: [ScriptEffect]) -> ConsiderSnapshot? {
        effects.compactMap { if case .updateConsider(let snapshot) = $0 { snapshot } else { nil } }.last
    }

    /// Run our own consider through the feature.
    private func considered(_ feature: inout ConsiderFeature, _ lines: [String]) -> ConsiderSnapshot? {
        _ = feature.handleCommand("conw")
        for text in lines {
            _ = feature.onLine(line(text))
        }
        return snapshot(feature.onLine(line(ConsiderFeature.endSentinel)).effects)
    }

    private func named(_ names: [String], room: Int?, at seconds: TimeInterval = 1) -> ActionableState {
        var state = ActionableState()
        state.occupants = Occupants(present: nil, since: .now, named: NamedOccupants(
            source: .consider,
            room: room,
            area: "aylor",
            at: Date(timeIntervalSince1970: seconds),
            mobs: names.map {
                NamedOccupant(
                    name: $0,
                    flags: ["R"],
                    tier: ConsiderTier.all[4],
                    unattackable: nil,
                    keyword: .init(keyword: "kw", source: .guess)
                )
            }
        ))
        return state
    }

    // MARK: - Soliciting (Q3)

    @Test("auto-refresh is on by default: entering a room considers, then the tagged sentinel")
    func autoByDefault() {
        var feature = ConsiderFeature()
        _ = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":3}"#)
        let effects = enter(&feature, room: 2)
        #expect(effects.contains(considerAll))
        #expect(effects.contains(.sendNoEcho("echo " + ConsiderFeature.endSentinel)))
    }

    @Test("auto-refresh off: entering a room sends nothing; conw still refreshes")
    func onDemand() {
        var feature = playingFeature(.off)
        #expect(!enter(&feature, room: 2).contains(considerAll))
        #expect(feature.handleCommand("conw")?.contains(considerAll) == true)
    }

    @Test("conw on, area and off each say what is now in effect, and save it")
    func modeMessages() {
        var feature = playingFeature()
        for (word, note) in [
            ("on", "Consider: auto-refresh on. The list refreshes as you move and as mobs come and go."),
            ("area", "Consider: auto-refresh on until you leave aylor."),
            ("off", "Consider: auto-refresh off. `conw` refreshes the list.")
        ] {
            let effects = feature.handleCommand("conw \(word)") ?? []
            #expect(effects.first == .echo(note))
            #expect(effects.contains(.persistPluginState(id: "com.proteles.consider")))
            #expect(snapshot(effects)?.auto == ConsiderAutoMode(rawValue: word))
        }
    }

    @Test("area mode switches off on leaving the zone, and says so")
    func areaMode() {
        var feature = playingFeature(.area)
        #expect(enter(&feature, room: 2).contains(considerAll))
        let effects = enter(&feature, room: 900, zone: "sirens")
        #expect(!effects.contains(considerAll))
        #expect(effects.contains(.persistPluginState(id: "com.proteles.consider")))
        #expect(snapshot(effects)?.auto == .off)
        #expect(!enter(&feature, room: 901, zone: "sirens").contains(considerAll))
    }

    @Test("on mode carries on across zones")
    func onModeAcrossZones() {
        var feature = playingFeature(.on)
        #expect(enter(&feature, room: 900, zone: "sirens").contains(considerAll))
    }

    @Test("a room entered mid-combat is considered when combat ends")
    func defersDuringCombat() {
        var feature = playingFeature(.on)
        _ = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":8}"#)
        #expect(!enter(&feature, room: 2).contains(considerAll))
        let ended = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":3}"#)
        #expect(ended.contains(considerAll))
    }

    @Test("mid-walk, rooms and arrivals wait; the walk's end considers once")
    func holdsDuringWalk() {
        var feature = playingFeature(.on)
        #expect(feature.onMapperBroadcast(id: 999, text: "kinda_busy").isEmpty)
        // State 3 between legs, as the game reports it at a portal landing.
        #expect(!enter(&feature, room: 2).contains(considerAll))
        #expect(!enter(&feature, room: 3).contains(considerAll))
        #expect(!feature.onLine(line("A goblin arrives from the north.")).effects.contains(considerAll))
        let ended = feature.onMapperBroadcast(id: 999, text: "ok_you_can_go_now")
        #expect(ended.filter { $0 == considerAll }.count == 1)
        // Nothing left owed: a later status change sends nothing.
        let idle = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":11}"#)
        #expect(!idle.contains(considerAll))
    }

    @Test("a walk's end sends nothing when nothing came due, mid-fight, or with auto off")
    func walkEndEdges() {
        var idle = playingFeature(.on)
        _ = idle.onMapperBroadcast(id: 999, text: "kinda_busy")
        #expect(idle.onMapperBroadcast(id: 999, text: "ok_you_can_go_now").isEmpty)

        var fighting = playingFeature(.on)
        _ = fighting.onMapperBroadcast(id: 999, text: "kinda_busy")
        _ = enter(&fighting, room: 2)
        _ = fighting.onGMCP(package: "char.status", json: #"{"level":100,"state":8}"#)
        #expect(!fighting.onMapperBroadcast(id: 999, text: "ok_you_can_go_now").contains(considerAll))
        let calm = fighting.onGMCP(package: "char.status", json: #"{"level":100,"state":3}"#)
        #expect(calm.contains(considerAll))

        var off = playingFeature(.off)
        _ = off.onMapperBroadcast(id: 999, text: "kinda_busy")
        _ = enter(&off, room: 2)
        #expect(off.onMapperBroadcast(id: 999, text: "ok_you_can_go_now").isEmpty)

        // Other mapper broadcasts (500 found_paths, …) aren't the walk's.
        var other = playingFeature(.on)
        _ = other.onMapperBroadcast(id: 500, text: "kinda_busy")
        #expect(enter(&other, room: 2).contains(considerAll))
    }

    @Test("the end sentinel finalizes a capture; a late duplicate is still gagged")
    func sentinel() {
        var feature = playingFeature()
        _ = feature.handleCommand("conw")
        #expect(feature.onLine(line(ConsiderFeature.endSentinel)).gag)
        #expect(feature.onLine(line(ConsiderFeature.endSentinel)).gag)
    }

    // MARK: - The state model (item 2)

    @Test("a consider someone else sent is adopted; our own isn't re-adopted")
    func adopts() throws {
        var feature = playingFeature()
        let adopted = try #require(snapshot(feature.onStateChange(
            named(["A goblin"], room: 1),
            changed: [.occupants]
        )))
        #expect(adopted.mobs.map(\.name) == ["A goblin"])
        #expect(adopted.mobs.first?.rawFlags == "(R)")
        // Another room's list is ignored.
        #expect(feature.onStateChange(named(["A rat"], room: 99, at: 2), changed: [.occupants]).isEmpty)
        // The same list again (a later occupant change) adopts nothing.
        #expect(feature.onStateChange(named(["A goblin"], room: 1), changed: [.occupants]).isEmpty)
    }

    @Test("a room the model knows has no mobs clears the list")
    func emptyRoomClears() {
        var feature = playingFeature()
        _ = considered(&feature, ["A goblin should be a fair fight!"])
        var state = ActionableState()
        state.occupants = Occupants(present: [Occupant(flags: ["P"], description: "Someone.")], since: .now)
        #expect(snapshot(feature.onStateChange(state, changed: [.occupants]))?.mobs.isEmpty == true)
    }

    // MARK: - Keywords (Q4)

    @Test("keywords come from the model's book, and re-key when it changes")
    func keywords() {
        var feature = playingFeature()
        var state = ActionableState()
        state.keywords = MobKeywordBook(exceptions: ["aylor": ["a male villager": "villag"]])
        _ = feature.onStateChange(state, changed: [.keywords])
        let first = considered(&feature, ["A male villager should be a fair fight!"])
        #expect(first?.mobs.first?.keyword == "villag")
        #expect(first?.mobs.first?.keywordSource == .snd)
        state.keywords.setOverride("villager", for: "a male villager", area: "aylor")
        let rekeyed = snapshot(feature.onStateChange(state, changed: [.keywords]))
        #expect(rekeyed?.mobs.first?.keyword == "villager")
        #expect(rekeyed?.mobs.first?.keywordSource == .player)
    }

    @Test("conw kw sets or clears the keyword for a list mob, in this area")
    func setKeyword() {
        var feature = playingFeature()
        _ = considered(&feature, ["A male villager should be a fair fight!"])
        #expect(feature.handleCommand("conw kw 1 villager")?.first
            == .setMobKeyword(name: "A male villager", area: "aylor", keyword: "villager"))
        #expect(feature.handleCommand("conw kw 1")?.first
            == .setMobKeyword(name: "A male villager", area: "aylor", keyword: nil))
        #expect(feature.handleCommand("conw kw 5 x")?
            .contains { if case .setMobKeyword = $0 { true } else { false } }
            == false)
    }

    // MARK: - Unattackable

    @Test("a mob with divine protection is listed, never attacked or swept")
    func unattackable() throws {
        var feature = playingFeature()
        let list = try #require(considered(&feature, [
            "Ayla has divine protection.",
            "A goblin should be a fair fight!"
        ]))
        #expect(list.mobs.map(\.rangeLabel) == ["divine protection", "-1 to +1"])
        #expect(feature.handleCommand("conw 1")?
            .contains { if case .execute = $0 { true } else { false } } == false)
        let sweep = feature.handleCommand("conwall") ?? []
        #expect(sweep.contains(.execute("kill 1.'gobli'")))
        #expect(!sweep.contains { if case .execute(let text) = $0 { text.contains("ayla") } else { false } })
    }

    @Test("saved settings from before the modes: auto on entry becomes on, else off")
    func legacySettings() throws {
        let on = #"{"enabled":true,"autoOnEntry":true,"autoOnCombatEnd":true,"executeMode":"cast","#
            + #""defaultCommand":"bs","options":{"skipGood":false,"skipAlignAuto":false,"minAoeCount":5,"#
            + #""skipSanctuary":false,"skipNeutral":false,"minLevel":-2,"skipEvil":false,"maxLevel":20,"#
            + #""aoeCommand":"c ultrablast","maxRoomCount":5,"maxAoeCount":-1}}"#
        let decoded = try JSONDecoder().decode(ConsiderSettings.self, from: Data(on.utf8))
        #expect(decoded.auto == .on)
        #expect(decoded.executeMode == .cast)
        #expect(decoded.defaultCommand == "bs")
        let off = on.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#)
        #expect(try JSONDecoder().decode(ConsiderSettings.self, from: Data(off.utf8)).auto == .off)
        let saved = try JSONEncoder().encode(ConsiderSettings(auto: .area))
        #expect(try JSONDecoder().decode(ConsiderSettings.self, from: saved).auto == .area)
    }

    // MARK: - Refreshing when who is here changes

    @Test("a mob arriving or fleeing refreshes the list; a player's thunderclap doesn't")
    func refreshOnArrival() {
        var feature = playingFeature(.on)
        _ = considered(&feature, ["A goblin should be a fair fight!"])
        #expect(feature.onLine(line("A troll warrior appears in the room.")).effects.contains(considerAll))
        _ = feature.onLine(line(ConsiderFeature.endSentinel))
        #expect(feature.onLine(line("A goblin has fled!")).effects.contains(considerAll))
        _ = feature.onLine(line(ConsiderFeature.endSentinel))
        #expect(!feature.onLine(line("With a thunderclap, Turnus appears in the room.")).effects
            .contains(considerAll))
    }

    @Test("with auto off, an arrival is listed but nothing is sent")
    func noRefreshWhenOff() {
        var feature = playingFeature(.off)
        _ = considered(&feature, ["A goblin should be a fair fight!"])
        let effects = feature.onLine(line("A troll warrior appears in the room.")).effects
        #expect(!effects.contains(considerAll))
        #expect(snapshot(effects)?.mobs.first?.detail == "arrived")
    }

    @Test("an arrival mid-fight refreshes once the fight ends")
    func arrivalDuringCombat() {
        var feature = playingFeature(.on)
        _ = considered(&feature, ["A goblin should be a fair fight!"])
        let (fighting, standing) = (#"{"level":100,"state":8}"#, #"{"level":100,"state":3}"#)
        _ = feature.onGMCP(package: "char.status", json: fighting)
        #expect(!feature.onLine(line("A troll warrior appears in the room.")).effects.contains(considerAll))
        #expect(feature.onGMCP(package: "char.status", json: standing).contains(considerAll))
        // A fight with no arrival ends quietly.
        _ = feature.onLine(line(ConsiderFeature.endSentinel))
        _ = feature.onGMCP(package: "char.status", json: fighting)
        #expect(!feature.onGMCP(package: "char.status", json: standing).contains(considerAll))
    }

    @Test("this area's repop refreshes the list; another area's doesn't")
    func refreshOnRepop() {
        var feature = playingFeature(.on)
        #expect(feature.onGMCP(package: "comm.repop", json: #"{ "zone": "aylor" }"#).contains(considerAll))
        _ = feature.onLine(line(ConsiderFeature.endSentinel))
        #expect(feature.onGMCP(package: "comm.repop", json: #"{ "zone": "light" }"#).isEmpty)
    }

    @Test("a refresh sends a new consider rather than reloading the list it holds")
    func refreshIsFresh() throws {
        var feature = playingFeature(.on)
        // Someone else's consider, adopted; then a kill marks the goblin dead.
        _ = feature.onStateChange(named(["A goblin", "A rat"], room: 1), changed: [.occupants])
        _ = feature.onLine(line("A goblin is DEAD!!"))
        let effects = feature.onLine(line("A rat has fled!")).effects
        #expect(effects.contains(considerAll))
        let list = try #require(snapshot(effects))
        #expect(list.mobs.first?.dead == true, "the dead goblin isn't revived")
    }
}

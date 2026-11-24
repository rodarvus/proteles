import Foundation
@testable import MudCore
import Testing

/// Occupants (S0b item 2, #84). Every fixture line is from a recording.
@Suite("Occupants")
struct OccupantsTests {
    private func line(_ text: String, at seconds: TimeInterval = 0) -> Line {
        Line(id: LineID(0), timestamp: Date(timeIntervalSince1970: seconds), text: text)
    }

    private typealias Tracker = ActionableStateTracker
    private typealias Change = ActionableStateTracker.Change

    private func feed(_ tracker: inout Tracker, _ texts: [String], at seconds: TimeInterval = 0) -> Change {
        var change = Change()
        for text in texts {
            change.merge(tracker.ingest(line(text, at: seconds)))
        }
        return change
    }

    // MARK: - Flags

    @Test("aura flags: short, long, spaced groups; the rest is the text")
    func flags() {
        let player = AuraFlags.split("(P)(F)(W) (OPK) Tinada the Chronicler [R/C].")
        #expect(player.flags == ["P", "F", "W", "OPK"])
        #expect(player.rest == "Tinada the Chronicler [R/C].")
        #expect(AuraFlags.isPlayer(player.flags))
        let long = AuraFlags.split("(Player) (Linkdead) Lews got the <-)light(->.")
        #expect(long.flags == ["Player", "Linkdead"])
        #expect(AuraFlags.isPlayer(long.flags))
        let mob = AuraFlags.split("(Golden Aura) (Hidden) A thief lurks here.")
        #expect(mob.flags == ["Golden Aura", "Hidden"])
        #expect(!AuraFlags.isPlayer(mob.flags))
        let bare = AuraFlags.split("Master of Pain")
        #expect(bare.flags.isEmpty)
        #expect(bare.rest == "Master of Pain")
    }

    // MARK: - Presence

    @Test("a {roomchars} block becomes presence; players counted, never mobs")
    func presence() throws {
        var tracker = ActionableStateTracker()
        let change = feed(&tracker, [
            "{roomchars}",
            "(P)(F)(T)(W) (OPK) Lorendale [R/C].",
            "(F) Reflection of Radience",
            "Cupid is here shooting arrows of love at the Lollipop Guild.",
            "{/roomchars}"
        ])
        #expect(change.entities == [.occupants])
        let occupants = try #require(tracker.state.occupants)
        #expect(occupants.present?.count == 3)
        #expect(occupants.mobs?.map(\.description) == [
            "Reflection of Radience", "Cupid is here shooting arrows of love at the Lollipop Guild."
        ])
        #expect(occupants.playerCount == 1)
        #expect(occupants.named == nil)
    }

    @Test("an identical heartbeat block changes no entity; an empty one does")
    func heartbeat() {
        var tracker = ActionableStateTracker()
        let block = [
            "{roomchars}",
            "(G) A celestial gull trails stardust as it paints constellations in its wake.",
            "{/roomchars}"
        ]
        _ = feed(&tracker, block)
        #expect(feed(&tracker, block, at: 3).entities.isEmpty)
        #expect(feed(&tracker, ["{roomchars}", "{/roomchars}"], at: 6).entities == [.occupants])
        #expect(tracker.state.occupants?.present?.isEmpty == true)
    }

    // MARK: - Names from scan

    @Test("{scan}'s Right here section names the room's mobs; other sections don't")
    func scanHere() throws {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(room: 100, area: "aylor")
        _ = feed(
            &tracker,
            ["{roomchars}", "(F)(G) A sunrise mallard gracefully weaves its way.", "{/roomchars}"]
        )
        let change = feed(&tracker, [
            "{scan}",
            "Right here you see:",
            "     - (F)(G) A sunrise mallard",
            "     - (P)(F)(W) Questant Rodarvus",
            "North from here you see:",
            "     - (G) A bold eagle",
            "{/scan}"
        ])
        #expect(change.entities == [.occupants])
        let named = try #require(tracker.state.occupants?.named)
        #expect(named.source == .scan)
        #expect(named.room == 100)
        #expect(named.mobs.map(\.name) == ["A sunrise mallard"])
        #expect(named.mobs.first?.keyword == .init(keyword: "sunri malla", source: .guess))
        #expect(tracker.state.occupants?.isNamedComplete == true)
    }

    @Test("a scan of adjacent rooms only leaves the names alone")
    func scanElsewhere() {
        var tracker = ActionableStateTracker()
        _ = feed(&tracker, ["{scan}", "North from here you see:", "     - (G) A bold eagle", "{/scan}"])
        #expect(tracker.state.occupants == nil)
    }

    // MARK: - Names from consider

    @Test("a whole-room consider is read once sent, skipping lines before it")
    func considerRun() throws {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(room: 7, area: "siege")
        _ = feed(
            &tracker,
            ["{roomchars}", "A kobold miner hacks at the rock.", "A mule is here.", "{/roomchars}"]
        )
        // Output before the command is never read.
        _ = feed(&tracker, ["A mule should be a fair fight!"])
        #expect(tracker.state.occupants?.named == nil)
        tracker.noteRoomConsider(at: Date(timeIntervalSince1970: 0))
        let change = feed(&tracker, [
            "<MAPSTART>",
            "(R) No Problem! A kobold miner is weak compared to you.",
            "A mule should be a fair fight!",
            "[2862/2862hp 2053/2295mn 277/305mv 22qt 8648tnl] Dbl: 7>"
        ])
        #expect(change.entities == [.occupants])
        let named = try #require(tracker.state.occupants?.named)
        #expect(named.source == .consider)
        #expect(named.mobs.map(\.name) == ["A kobold miner", "A mule"])
        #expect(named.mobs.map(\.tier?.rangeLabel) == ["-5 to -9", "-1 to +1"])
        #expect(named.mobs.first?.flags == ["R"])
        #expect(tracker.state.occupants?.isNamedComplete == true)
        #expect(tracker.state.status(of: .consider).blocks == 1)
        #expect(!tracker.considerWindow.isOpen)
    }

    @Test("unattackable lines are named, flagged, never tiered")
    func unattackable() throws {
        var tracker = ActionableStateTracker()
        tracker.noteRoomConsider()
        _ = feed(&tracker, [
            "Ayla has divine protection.",
            "If you killed The baker, who would serve all his customers?",
            "prompt>"
        ])
        let mobs = try #require(tracker.state.occupants?.named?.mobs)
        #expect(mobs.map(\.unattackable) == [.divineProtection, .shopkeeper])
        #expect(mobs.allSatisfy { $0.tier == nil })
        #expect(tracker.state.occupants?.present == nil)
    }

    @Test("the reference plugin's other unattackable lines name the mob")
    func unattackableReference() {
        let lines = [
            "Ayla would not approve of you killing Commander Dahr!",
            "Ayla would smite you for killing Commander Dahr!",
            "(R) A hungry rat has already been challenged."
        ].compactMap(ConsiderLine.parse)
        #expect(lines.map(\.name) == ["Commander Dahr", "Commander Dahr", "A hungry rat"])
        #expect(lines.map(\.unattackable) == [.wouldNotApprove, .wouldSmite, .alreadyChallenged])
        #expect(lines.last?.flags == ["R"])
    }

    @Test("a challenged mob inside a run is one of its mobs, not its end")
    func challengedInRun() throws {
        // session-20260821-131406, 18:48:30.
        var tracker = ActionableStateTracker()
        tracker.noteRoomConsider()
        _ = feed(&tracker, [
            "(H)(R) A creepy spider chuckles at the thought of you fighting it.",
            "(H)(R) A squeaking rat chuckles at the thought of you fighting it.",
            "A cloud of dust mites has already been challenged.",
            "A cloud of dust mites has already been challenged.",
            "A hungry rat has already been challenged.",
            "(H)(R) A creepy spider chuckles at the thought of you fighting it.",
            "[2537/3541hp 2431/3087mn 800/800mv 23qt 5043tnl] Dbl: 6>"
        ])
        let mobs = try #require(tracker.state.occupants?.named?.mobs)
        #expect(mobs.count == 6)
        #expect(mobs.filter { $0.unattackable == .alreadyChallenged }.count == 3)
        #expect(tracker.state.status(of: .consider).blocks == 1)
    }

    @Test("a consider sent mid-speedwalk is read after the walk's output")
    func considerAfterSpeedwalk() throws {
        // session-20260821-131406: answers came up to 1,435 lines and 8 s later.
        var tracker = ActionableStateTracker()
        tracker.noteRoomConsider(at: Date(timeIntervalSince1970: 0))
        _ = feed(&tracker, Array(repeating: "Hall of the Damned", count: 1000), at: 5)
        _ = feed(&tracker, ["A mule should be a fair fight!", "prompt>"], at: 8)
        #expect(try #require(tracker.state.occupants?.named?.mobs).map(\.name) == ["A mule"])
    }

    @Test("an unanswered consider's clock doesn't end the next one's run")
    func staleSend() throws {
        var tracker = ActionableStateTracker()
        tracker.noteRoomConsider(at: Date(timeIntervalSince1970: 0))
        _ = feed(&tracker, ["Gateway to Hell"], at: 1)
        tracker.noteRoomConsider(at: Date(timeIntervalSince1970: 15))
        _ = feed(&tracker, ["The Warren"], at: 21)
        _ = feed(&tracker, ["A mule should be a fair fight!", "prompt>"], at: 22)
        #expect(try #require(tracker.state.occupants?.named?.mobs).map(\.name) == ["A mule"])
    }

    @Test("an empty room gives an empty list; a refused command closes in time")
    func emptyAndAbandoned() {
        var tracker = ActionableStateTracker()
        tracker.noteRoomConsider()
        _ = feed(&tracker, ["You see no one here but yourself!"])
        #expect(tracker.state.occupants?.named?.mobs.isEmpty == true)
        #expect(!tracker.considerWindow.isOpen)

        tracker.noteRoomConsider(at: Date(timeIntervalSince1970: 0))
        _ = feed(&tracker, ["You can't do that while asleep."], at: 1)
        #expect(tracker.considerWindow.isOpen)
        _ = feed(&tracker, ["Some later line."], at: 30)
        #expect(!tracker.considerWindow.isOpen)
    }

    @Test("a scan never replaces this room's consider list; leaving the room drops names")
    func precedence() {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(room: 7, area: "siege")
        tracker.noteRoomConsider()
        _ = feed(&tracker, ["A mule should be a fair fight!", "prompt>"])
        _ = feed(&tracker, ["{scan}", "Right here you see:", "     - (G) A horse", "{/scan}"])
        #expect(tracker.state.occupants?.named?.source == .consider)
        let left = tracker.ingest(room: 8, area: "siege")
        #expect(left.entities == [.occupants])
        #expect(tracker.state.occupants?.named == nil)
    }

    @Test("only whole-room considers open a window")
    func roomConsider() {
        for command in ["con", "consider", "cons all", "CONSIDER ALL"] {
            #expect(ConsiderWindow.isRoomConsider(command), "\(command)")
        }
        for command in ["co", "conw", "consider rat", "con all rats", "converse"] {
            #expect(!ConsiderWindow.isRoomConsider(command), "\(command)")
        }
    }

    // MARK: - Keywords

    @Test("an override re-keys the named mobs and reports the entity")
    func override() {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(room: 1, area: "radiance")
        _ = tracker.setKeywordBook(MobKeywordBook(exceptions: ["radiance": ["a male villager": "villag"]]))
        tracker.noteRoomConsider()
        _ = feed(&tracker, ["A male villager should be a fair fight!", "prompt>"])
        #expect(tracker.state.occupants?.named?.mobs.first?.keyword == .init(keyword: "villag", source: .snd))
        let change = tracker.setKeywordOverride("villager", for: "A male villager", area: "radiance")
        #expect(change.entities == [.keywords, .occupants])
        #expect(tracker.state.occupants?.named?.mobs.first?.keyword == .init(
            keyword: "villager",
            source: .player
        ))
        tracker.reset()
        #expect(tracker.state.keywords.overrides == ["radiance": ["a male villager": "villager"]])
    }
}

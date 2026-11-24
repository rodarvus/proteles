import Foundation
@testable import MudCore
import Testing

/// Recorded scenes replayed through the state model and the Consider feature
/// together, wired as the session wires them: the tracker sees each line and
/// GMCP packet first, the feature hears of state changes, and a whole-room
/// `consider` the feature sends opens the tracker's window.
@Suite("Consider replays")
struct ConsiderReplayTests {
    private struct Rig {
        var tracker = ActionableStateTracker()
        var feature = ConsiderFeature()
        var sent: [String] = []
        /// Each send with the time of the line that caused it.
        var sentAt: [(String, String)] = []
        var last: ConsiderSnapshot?
        private var now = ""

        mutating func play(_ script: String) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for raw in script.split(separator: "\n") {
                let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let date = iso.date(from: "2026-10-31T\(parts[0])Z")
                else { continue }
                now = String(parts[0])
                let body = String(parts[2])
                switch parts[1] {
                case "INPUT":
                    apply(feature.handleCommand(body) ?? [], at: date)
                case "GMCP":
                    let packet = body.split(separator: " ", maxSplits: 1).map(String.init)
                    notify(tracker.ingest(gmcpPackage: packet[0], json: packet[1], at: date))
                    apply(feature.onGMCP(package: packet[0], json: packet[1]), at: date)
                case "RECV" where body == "{begin running}" || body == "{end running}":
                    // The session consumes the reflected marker and broadcasts
                    // 999 to plugins (`SessionController.handleWalkMarker`).
                    let text = body == "{begin running}" ? "kinda_busy" : "ok_you_can_go_now"
                    apply(feature.onMapperBroadcast(id: 999, text: text), at: date)
                default:
                    let line = Line(id: LineID(0), timestamp: date, text: body)
                    notify(tracker.ingest(line))
                    apply(feature.onLine(line).effects, at: date)
                }
            }
        }

        private mutating func notify(_ change: ActionableStateTracker.Change) {
            guard !change.entities.isEmpty else { return }
            apply(feature.onStateChange(tracker.state, changed: change.entities), at: .now)
        }

        private mutating func apply(_ effects: [ScriptEffect], at date: Date) {
            for effect in effects {
                switch effect {
                case .sendNoEcho(let command):
                    sent.append(command)
                    sentAt.append((command, now))
                    if ConsiderWindow.isRoomConsider(command) { tracker.noteRoomConsider(at: date) }
                case .updateConsider(let snapshot):
                    last = snapshot
                default:
                    break
                }
            }
        }
    }

    /// session-20261031-065653, 07:36:51–07:37:59 (zenith, times UTC),
    /// abridged to the lines the feature reads, GMCP packets cut to the
    /// fields read. The previous room's `room.info` is shortened.
    private static let zenithKills = """
    07:36:51.766 GMCP char.status { "level": 201, "tnl": 363, "align": -49, "state": 3, "pos": "Standing" }
    07:36:52.000 GMCP room.info {"num":23681,"name":"r","zone":"zenith","details":""}
    07:36:54.112 INPUT conw on
    07:37:02.245 GMCP room.info { "num": 23684, "name": "Gossamer Mistwillows", "zone": "zenith" }
    07:37:02.625 RECV (R) A wetland spite snickers nervously.
    07:37:02.625 RECV (R) A red-bellied lieweaver snickers nervously.
    07:37:02.625 RECV (G) A songweaver snickers nervously.
    07:37:02.625 RECV (G) A radiant ibis snickers nervously.
    07:37:03.022 RECV { consider }
    07:37:20.291 GMCP char.status { "level": 201, "align": -49, "state": 8 }
    07:37:20.683 GMCP char.status { "level": 201, "align": -35, "state": 3, "pos": "Standing" }
    07:37:20.688 RECV A wetland spite smoulders as the lightning destroys it!!
    07:37:27.614 RECV A radiant ibis flutters south.
    07:37:49.118 GMCP char.status { "level": 201, "align": -35, "state": 8 }
    07:37:50.786 GMCP char.status { "level": 201, "align": -21, "state": 3, "pos": "Standing" }
    07:37:50.789 RECV A red-bellied lieweaver smoulders as the lightning destroys it!!
    07:37:59.269 GMCP char.status { "level": 201, "align": -21, "state": 8 }
    07:37:59.805 GMCP char.status { "level": 201, "align": -34, "state": 3, "pos": "Standing" }
    07:37:59.809 RECV A songweaver smoulders as the lightning destroys it!!
    """

    /// What was saved before the modes (the old defaults, auto switched off
    /// by a zone change).
    private static let legacySettings = #"""
    {"enabled":false,"autoOnCombatEnd":true,"executeMode":"skill","defaultCommand":"kill",
     "autoOnEntry":true,"options":{"skipGood":false,"skipAlignAuto":false,"minAoeCount":5,
     "skipSanctuary":false,"skipNeutral":false,"minLevel":-2,"skipEvil":false,"maxLevel":20,
     "aoeCommand":"c ultrablast","maxRoomCount":5,"maxAoeCount":-1}}
    """#

    /// session-20261121-084649, 09:42:32–36: `xcp 1` to a campaign mob, a
    /// portal then a `run`. The recording sent three considers (on the portal
    /// landing, on the run's first room, on arrival), all three answered in
    /// the mob's room. Packets cut to the fields read; the start room is
    /// shortened.
    private static let campaignWalk = """
    09:42:32.000 GMCP char.status { "level": 201, "align": 2237, "state": 3, "pos": "Standing" }
    09:42:32.100 GMCP room.info { "num": 39628, "name": "r", "zone": "oceanpark", "details": "" }
    09:42:33.392 RECV {begin running}
    09:42:34.510 GMCP room.info { "num": 28144, "name": "Beginning of Palace Street", "zone": "arisian" }
    09:42:35.064 GMCP room.info { "num": 24618, "name": "The Desolate Pridelands", "zone": "abend" }
    09:42:35.067 GMCP char.status { "level": 201, "align": 2237, "state": 12, "pos": "Standing" }
    09:42:35.170 GMCP room.info { "num": 24619, "name": "The Forbidden Waters", "zone": "abend" }
    09:42:36.039 GMCP room.info { "num": 35117, "name": "In the Forest", "zone": "ketu" }
    09:42:36.477 GMCP room.info { "num": 35115, "name": "The Great Plains", "zone": "ketu" }
    09:42:36.524 GMCP char.status { "level": 201, "align": 2237, "state": 3, "pos": "Standing" }
    09:42:36.583 RECV {end running}
    """

    @Test("a walk to a campaign mob considers once, when the walk ends, not on the way")
    func campaignWalkConsidersOnce() {
        var rig = Rig()
        rig.feature.settings.auto = .on
        rig.play(Self.campaignWalk)
        // The first is the start room's, before the walk.
        #expect(rig.sent.filter { $0 == "consider all" }.count == 2)
        #expect(rig.sentAt.last { $0.0 == "consider all" }?.1 == "09:42:36.583")
    }

    @Test("killed mobs stay dead through each fight's end; the ibis has left, not died")
    func zenithKillsStayDead() throws {
        var rig = Rig()
        rig.feature.restore(from: Data(Self.legacySettings.utf8))
        rig.play(Self.zenithKills)
        let mobs = try #require(rig.last?.mobs)
        #expect(mobs.map(\.name) == [
            "A wetland spite", "A red-bellied lieweaver", "A songweaver", "A radiant ibis"
        ])
        #expect(mobs.map(\.dead) == [true, true, true, false])
        #expect(mobs[3].left)
        #expect(mobs[3].detail == "left south")
        // One consider, on entering the room: none after the kills.
        #expect(rig.sent.filter { $0 == "consider all" }.count == 1)
    }
}

import Foundation
@testable import MudCore

/// The actionable-state frame replayed over the corpus (S0b item 1, #84;
/// `docs/plans/S0B_ITEM1_PROPOSAL.md` §3.5). The production tracker ingests
/// every decoded line and GMCP message in order, and the result is held two
/// ways, as for events and cues:
///
/// - **Invariant:** an independent count of opening/closing marker pairs,
///   by plain prefix matching, must equal the tracker's completed blocks per
///   feed, and no block may be incomplete. Each incomplete block is listed by
///   line index, so a real one is visible rather than silently dropped.
///   Likewise, independent counts of tag lines (by prefix) and GMCP packages
///   (by name) must equal each tag-line and GMCP feed's arrivals.
/// - **Pin:** which feeds a session saw and its blocks per feed, in its own
///   baseline. Later S0b items add their entities' pins here.
///
/// Occupants (item 2) add two invariants, each against a recogniser written
/// here a second time: every `{roomchars}` block's non-player count equals
/// the model's mobs (players are never mobs), and a named list always
/// belongs to the room `room.info` last named. Consider windows open at the
/// `.log`'s `SEND` times (`CorpusReplay+Sends.swift`).
struct StateRecorder {
    /// What is pinned per session.
    struct Pin: Codable, Equatable {
        var seen: [String] = []
        var blocks: [String: Int] = [:]
        /// Item 2. Optional so an item 1 baseline reads as "differs", for a
        /// deliberate re-pin.
        var occupants: OccupantPin?
    }

    struct OccupantPin: Codable, Equatable {
        /// Presence changes (not heartbeat repeats).
        var presenceChanges = 0
        /// Named lists set, and their mobs, per source.
        var namedLists: [String: Int] = [:]
        var namedMobs: [String: Int] = [:]
        /// Lists that counted as many mobs as were present.
        var completeLists = 0
        /// Whole-room considers sent, and how many the window read.
        var considersSent = 0
        var considerRuns = 0
    }

    private var tracker = ActionableStateTracker()
    private var open: (feed: ActionableState.Feed, index: Int)?
    private var occupantPin = OccupantPin()
    private var roomcharsLines: [String] = []
    private var room: Int?
    private(set) var occupantViolations: [String] = []
    /// Whole-room consider send times still to come (`CorpusReplay+Sends.swift`).
    var considerSends: ArraySlice<Date> = []
    private(set) var independentBlocks: [String: Int] = [:]
    private(set) var independentArrivals: [String: Int] = [:]
    private(set) var incomplete: [String] = []

    var pin: Pin {
        var pin = Pin()
        for feed in ActionableState.Feed.allCases where tracker.state.status(of: feed).isSeen {
            pin.seen.append(feed.rawValue)
            if feed.kind == .tagBlock { pin.blocks[feed.rawValue] = tracker.state.status(of: feed).blocks }
        }
        var occupants = occupantPin
        occupants.considerRuns = tracker.state.status(of: .consider).blocks
        pin.occupants = occupants
        return pin
    }

    /// A whole-room `consider` was sent (from the `.log`).
    mutating func noteRoomConsider() {
        tracker.noteRoomConsider()
        occupantPin.considersSent += 1
    }

    /// Open the window for every consider sent at or before `date` — the
    /// arrival time of the bytes about to be replayed.
    mutating func openConsiders(sentBy date: Date) {
        while let sent = considerSends.first, sent <= date {
            considerSends.removeFirst()
            noteRoomConsider()
        }
    }

    mutating func observe(_ line: Line, index: Int) {
        let before = tracker.state
        let change = tracker.ingest(line)
        countIndependently(line.text, index: index)
        if change.entities.contains(.occupants) { checkOccupants(before: before.occupants, index: index) }
        for feed in ActionableState.Feed.allCases where feed.kind == .tagBlock {
            let was = before.status(of: feed).incompleteBlocks
            if tracker.state.status(of: feed).incompleteBlocks > was {
                let reason = tracker.state.status(of: feed).lastIncomplete?.reason.rawValue ?? "?"
                incomplete.append("\(index): {\(feed.rawValue)} block \(reason)")
            }
        }
    }

    mutating func observe(gmcp message: GMCPMessage) {
        _ = tracker.ingest(gmcpPackage: message.package, json: message.json)
        checkRoom(message)
        let name = message.package.lowercased()
        if ActionableState.Feed.allCases.contains(where: { $0.kind == .gmcp && $0.rawValue == name }) {
            independentArrivals[name, default: 0] += 1
        }
    }

    /// The tracker's arrivals per tag-line and GMCP feed, zeros omitted.
    var arrivals: [String: Int] {
        var out: [String: Int] = [:]
        for feed in ActionableState.Feed.allCases where feed.kind != .tagBlock {
            let count = tracker.state.status(of: feed).arrivals
            if count > 0 { out[feed.rawValue] = count }
        }
        return out
    }

    /// The second recogniser: `{family}` / `{family args}` opens, `{/family}`
    /// closes, and a pair counts only when nothing interrupts it.
    private mutating func countIndependently(_ text: String, index: Int) {
        if open?.feed == .roomchars, !text.hasPrefix("{") { roomcharsLines.append(text) }
        guard text.hasPrefix("{") else { return }
        for feed in ActionableState.Feed.allCases where feed.kind == .tagLine {
            if text.hasPrefix("{\(feed.rawValue)}") || text.hasPrefix("{\(feed.rawValue) ") {
                independentArrivals[feed.rawValue, default: 0] += 1
                return
            }
        }
        for feed in ActionableState.Feed.allCases where feed.kind == .tagBlock {
            let name = feed.rawValue
            if text.hasPrefix("{/\(name)}") {
                if open?.feed == feed {
                    independentBlocks[name, default: 0] += 1
                    if feed == .roomchars { checkMobCount(index: index) }
                }
                open = nil
                return
            }
            if text.hasPrefix("{\(name)}") || text.hasPrefix("{\(name) ") {
                open = (feed, index)
                roomcharsLines = []
                return
            }
        }
    }

    /// The second player recogniser: any leading flag group reading `P` or
    /// `Player` (`help auras`).
    private static let playerLine = try? NSRegularExpression(pattern: #"^(?:\([^()]*\) ?)*\((?:P|Player)\)"#)

    private mutating func checkMobCount(index: Int) {
        let players = roomcharsLines.count { text in
            Self.playerLine?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        let mobs = tracker.state.occupants?.mobs?.count
        if mobs != roomcharsLines.count - players {
            occupantViolations.append("\(index): mobs \(mobs.map(String.init) ?? "nil") ≠ independent "
                + "\(roomcharsLines.count - players)")
        }
    }

    /// The room, read independently, and no names kept from another room.
    private mutating func checkRoom(_ message: GMCPMessage) {
        guard message.package.lowercased() == "room.info",
              let object = try? JSONSerialization.jsonObject(with: Data(message.json.utf8)) as? [String: Any]
        else { return }
        room = (object["num"] as? NSNumber)?.intValue
        guard let named = tracker.state.occupants?.named, named.room != room else { return }
        occupantViolations
            .append("room \(room.map(String.init) ?? "nil"): kept room \(named.room ?? -1)'s names")
    }

    private mutating func checkOccupants(before: Occupants?, index: Int) {
        guard let occupants = tracker.state.occupants else { return }
        if occupants.present != before?.present { occupantPin.presenceChanges += 1 }
        guard let named = occupants.named, named != before?.named else { return }
        occupantPin.namedLists[named.source.rawValue, default: 0] += 1
        occupantPin.namedMobs[named.source.rawValue, default: 0] += named.mobs.count
        if occupants.isNamedComplete { occupantPin.completeLists += 1 }
        if named.room != room {
            occupantViolations.append("\(index): names bound to room \(named.room ?? -1), in \(room ?? -1)")
        }
    }

    /// Disagreements with the independent count, and every incomplete block.
    func violations(session: String) -> [String] {
        var out = incomplete.map { "\(session) state: incomplete \($0)" }
        out += occupantViolations.map { "\(session) occupants: \($0)" }
        let mine = pin.blocks.filter { $0.value > 0 }
        if mine != independentBlocks {
            out.append("\(session) state: blocks \(mine.sorted { $0.key < $1.key }) "
                + "≠ independent \(independentBlocks.sorted { $0.key < $1.key })")
        }
        if arrivals != independentArrivals {
            out.append("\(session) state: arrivals \(arrivals.sorted { $0.key < $1.key }) "
                + "≠ independent \(independentArrivals.sorted { $0.key < $1.key })")
        }
        return out
    }
}

extension CorpusReplay {
    static var stateBaselineDirectory: URL {
        realHome.appendingPathComponent(
            "Documents/Proteles/Diagnostics/replay-state-baseline",
            isDirectory: true
        )
    }

    static func loadStatePin(at url: URL) -> StateRecorder.Pin? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StateRecorder.Pin.self, from: data)
    }

    /// Compare a session's state pin to its baseline (pinning on first sight
    /// or under `PROTELES_REPLAY_PIN`). Returns a report when they differ.
    static func checkState(
        _ replayed: Replayed,
        directory: URL = stateBaselineDirectory
    ) throws -> String? {
        let name = replayed.session.name
        let url = directory.appendingPathComponent("\(name).json")
        if !shouldPin, let baseline = loadStatePin(at: url) {
            guard baseline != replayed.state else { return nil }
            return "\(name): state differs\n  was \(baseline)\n  now \(replayed.state)"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(replayed.state).write(to: url)
        return nil
    }
}

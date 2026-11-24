import Foundation
@testable import MudCore

/// One recording's log replayed through the state model and the Consider
/// feature, wired as the session wires them (`ConsiderReplayTests.Rig`, over
/// a whole session): the tracker sees each line and GMCP packet first, the
/// feature hears of state changes, and each whole-room `consider` the
/// recording sent opens the tracker's window at its `SEND` time.
///
/// Replay is open-loop: the server's answers are fixed. So two features run:
///
/// - **The list** (auto off) shows only the considers the recording made,
///   which have answers, and is held to ``ConsiderAudit``'s invariants.
/// - **What auto-refresh would send** (auto on) runs beside it. Its own
///   `consider all` gets no answer here, so each is closed at once with the
///   sentinel; what is measured is when and how often it would send.
struct ConsiderScenarioReplay {
    struct Arrivals {
        /// The next consider in that room listed the name, or didn't.
        var confirmed = 0
        var contradicted = 0
        /// No consider in that room before leaving it.
        var unchecked = 0
        var byName: [String: [Int]] = [:]

        mutating func tally(_ name: String, _ slot: Int) {
            byName[name, default: [0, 0, 0]][slot] += 1
        }
    }

    struct WouldSend {
        var byReason: [String: Int] = [:]
        /// Sent in a room left within two seconds: the walk was passing
        /// through. (State 12, running, comes only after a `run`'s first
        /// room, and not at all between segments.)
        var passingThrough = 0
        var whileFighting = 0
        /// The most sent in any ten seconds.
        var peakIn10s = 0
        var recordedConsiders = 0
        var hours = 0.0

        var total: Int {
            byReason.values.reduce(0, +)
        }
    }

    struct Result {
        let name: String
        var audit = ConsiderAudit()
        var arrivals = Arrivals()
        var wouldSend = WouldSend()
    }

    private var tracker = ActionableStateTracker()
    private var list = ConsiderFeature()
    private var auto = ConsiderFeature()
    private var result: Result
    private var room: Int?
    private var state: Int?
    /// When the what-if feature sent in the current room.
    private var roomSends: [Double] = []
    private var pending: [String] = []
    private var lastConsiderAt: Date?
    private var recentSends: [Double] = []
    private var place = ""

    private init(name: String) {
        result = Result(name: name)
        list.settings.auto = .off
        auto.settings.auto = .on
    }

    static func replay(_ url: URL) throws -> Result {
        var rig = ConsiderScenarioReplay(name: url.deletingPathExtension().lastPathComponent)
        var first: Double?
        var last = 0.0
        try RecordingLog.forEach(url, kinds: [.recv, .gmcp, .send]) { entry in
            first = first ?? entry.time
            last = entry.time
            rig.play(entry)
            return true
        }
        rig.result.arrivals.unchecked += rig.pending.count
        rig.result.wouldSend.hours = first.map { (last - $0) / 3600 } ?? 0
        return rig.result
    }

    private mutating func play(_ entry: RecordingLog.Entry) {
        place = "\(result.name) \(Self.clock(entry.time))"
        switch entry.kind {
        case .send:
            guard ConsiderWindow.isRoomConsider(entry.body) else { return }
            tracker.noteRoomConsider(at: entry.date)
            result.wouldSend.recordedConsiders += 1
        case .gmcp:
            let parts = entry.body.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            observeGMCP(parts[0].lowercased(), parts[1], at: entry.time)
            notify(tracker.ingest(gmcpPackage: parts[0], json: parts[1], at: entry.date))
            observeList(list.onGMCP(package: parts[0], json: parts[1]), line: nil)
            observeAuto(
                auto.onGMCP(package: parts[0], json: parts[1]),
                reason: parts[0].lowercased(),
                at: entry.time
            )
        case .recv where entry.body == "{begin running}" || entry.body == "{end running}":
            // The session consumes the reflected marker and broadcasts 999.
            // Recordings from before the walk-end fix lack some ends.
            let text = entry.body == "{begin running}" ? "kinda_busy" : "ok_you_can_go_now"
            _ = list.onMapperBroadcast(id: 999, text: text)
            observeAuto(auto.onMapperBroadcast(id: 999, text: text), reason: "walk end", at: entry.time)
        case .recv:
            let line = Line(id: LineID(0), timestamp: entry.date, text: entry.body)
            notify(tracker.ingest(line))
            let before = result.audit.lastMobs
            observeList(list.onLine(line).effects, line: entry.body)
            result.audit.noteLine(entry.body, before: before, at: place)
            observeAuto(auto.onLine(line).effects, reason: "line", at: entry.time)
        default:
            break
        }
    }

    /// The room and player state, read here a second time.
    private mutating func observeGMCP(_ package: String, _ json: String, at time: Double) {
        guard package == "room.info" || package == "char.status",
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return }
        if package == "char.status" {
            state = (object["state"] as? NSNumber)?.intValue ?? state
            return
        }
        let num = (object["num"] as? NSNumber)?.intValue
        guard num != room else { return }
        result.wouldSend.passingThrough += roomSends.count { time - $0 < 2 }
        roomSends = []
        result.arrivals.unchecked += pending.count
        for name in pending {
            result.arrivals.tally(name, 2)
        }
        pending = []
        room = num
    }

    private mutating func notify(_ change: ActionableStateTracker.Change) {
        guard !change.entities.isEmpty else { return }
        checkArrivals()
        observeList(list.onStateChange(tracker.state, changed: change.entities), line: nil)
        _ = auto.onStateChange(tracker.state, changed: change.entities)
    }

    /// A new consider list for this room settles the arrivals seen since.
    private mutating func checkArrivals() {
        guard let named = tracker.state.occupants?.named, named.source == .consider,
              named.room == room, named.at != lastConsiderAt
        else { return }
        lastConsiderAt = named.at
        let listed = Set(named.mobs.map { $0.name.lowercased() })
        for name in pending {
            let found = listed.contains(name.lowercased())
            result.arrivals.tally(name, found ? 0 : 1)
            if found { result.arrivals.confirmed += 1 } else { result.arrivals.contradicted += 1 }
        }
        pending = []
    }

    private mutating func observeList(_ effects: [ScriptEffect], line: String?) {
        for case .updateConsider(let snapshot) in effects {
            result.audit.observe(snapshot.mobs, line: line, at: place)
            pending += result.audit.newArrivals
        }
    }

    /// `PROTELES_SCENARIO_FROM` (ISO 8601): count would-be sends only from
    /// then, to compare with a session where `conw on` was typed part-way.
    private static let countFrom: Double? = ProcessInfo.processInfo.environment["PROTELES_SCENARIO_FROM"]
        .flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }

    private mutating func observeAuto(_ effects: [ScriptEffect], reason: String, at time: Double) {
        for case .sendNoEcho(let command) in effects where command == "consider all" {
            // Still closed below, so the run doesn't stay open uncounted.
            let counted = Self.countFrom.map { time >= $0 } ?? true
            if counted { result.wouldSend.byReason[reason, default: 0] += 1 }
            roomSends.append(time)
            if state == 8 { result.wouldSend.whileFighting += 1 }
            recentSends = recentSends.filter { time - $0 < 10 } + [time]
            result.wouldSend.peakIn10s = max(result.wouldSend.peakIn10s, recentSends.count)
            // No answer will come: close the run so the next can start.
            _ = auto.onLine(Line(id: LineID(0), text: ConsiderFeature.endSentinel))
        }
    }

    /// `HH:MM:SS` UTC, as the `.log`'s own `Z` times read.
    static func clock(_ time: Double) -> String {
        let seconds = Int(time) % 86400
        return String(format: "%02d:%02d:%02dZ", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

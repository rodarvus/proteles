import Foundation
@testable import MudCore

/// The recordings' walks replayed through the real ``SessionController`` and
/// ``Mapper`` (the walk-end fix): every walk the recording started, from its
/// `Walking to … [uid]` note, through to how it ended.
///
/// A window opens at each such note and runs until the replayed walk is over
/// (plus a three-second tail, where a stray segment would show) or two
/// minutes pass. Within it the recording's received lines and GMCP go through
/// `processChunk`, the session's own inbound entry point, and the player's
/// `mapper stop` and each further walk are fired as the recording had them.
///
/// Replay is open-loop: the server's answers are the recording's. One answer
/// is closed instead: `echo` comes straight back, so each marker the replay
/// sends is reflected to it at once, and the recording's own reflections (of
/// the old client's markers) are dropped. That makes the 999 broadcast a
/// thing the replay can check.
///
/// The map is a copy of the live database, so a route may differ from the
/// one recorded; each window says whether its first segment matched.
final class WalkScenarioReplay {
    struct Result {
        let name: String
        var windows: [WalkAudit.Recorded: Int] = [:]
        var failures: [String: Int] = [:]
        var violations: [String] = []
        var resolved = 0
        var unresolved = 0
        /// Unresolved windows whose walk still owed its end: the silent stall.
        var unresolvedOwingEnd = 0
        var paced = 0
        var noRoute = 0
        var cancelled = 0
        var routeAgreed = 0
        var routeCompared = 0
        /// 999 broadcasts heard in windows: zero would mean the reflected
        /// markers never reached the session.
        var broadcasts = 0
        /// What the first violating windows sent and heard, to read beside
        /// the recording.
        var traces: [String] = []
    }

    private struct Open {
        var window = WalkAudit.Window()
        let opened: Double
        let sentMark: Int
        let heardMark: Int
        var recorded: WalkAudit.Recorded?
        var recordedBegun = false
        var recordedFirst: String?
        var resolvedAt: Double?
        var segments: [String] = []
        let place: String
    }

    static let tail = 3.0
    static let cap = 120.0
    private static let walkNote = try? NSRegularExpression(pattern: #"^Walking to .*\[(-?\d+)\] — "#)

    private let controller: SessionController
    private let engine: ScriptEngine
    private let conn: InMemoryConnection
    private let mapper: Mapper
    private var result: Result
    private var open: Open?
    private var reflectedMark = 0
    private var heardCount = 0
    private var lastRoom: String?
    private var lastStatus: String?
    private var lastInput: (time: Double, text: String)?
    private var lastWindowPaced = false

    private init(name: String, mapper: Mapper) async throws {
        result = Result(name: name)
        self.mapper = mapper
        engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: Self.listener))
        let conn = InMemoryConnection()
        self.conn = conn
        controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        await controller.attachMapper(mapper)
        try await controller.connect(to: .init(host: "replay.invalid", port: 23))
        reflectedMark = conn.sendCount
    }

    /// Records every 999 broadcast it hears.
    private static let listener = """
    <muclient>
    <plugin id="com.test.walk-replay" name="WalkReplay" save_state="n"/>
    <script><![CDATA[
    heard = {}
    function OnPluginBroadcast(msg, id, name, text)
      if msg == 999 then table.insert(heard, text) end
    end
    ]]></script>
    </muclient>
    """

    static func replay(_ url: URL, mapper: Mapper) async throws -> Result {
        let rig = try await WalkScenarioReplay(
            name: url.deletingPathExtension().lastPathComponent,
            mapper: mapper
        )
        var reader = try RecordingLog.Reader(url, kinds: [.recv, .gmcp, .send, .input, .note])
        while let entry = reader.next() {
            await rig.play(entry)
        }
        await rig.finish()
        return rig.result
    }

    // MARK: - Driving the session

    private func play(_ entry: RecordingLog.Entry) async {
        switch entry.kind {
        case .gmcp:
            if entry.body.hasPrefix("room.info ") { lastRoom = entry.body }
            if entry.body.hasPrefix("char.status ") { lastStatus = entry.body }
        case .input:
            lastInput = (entry.time, entry.body.lowercased())
        default:
            break
        }
        if case .note = entry.kind, let uid = walkTarget(entry.body) {
            await startWalk(uid, at: entry)
            return
        }
        guard open != nil else { return }
        await feed(entry)
        await settle(at: entry.time)
    }

    private func walkTarget(_ note: String) -> String? {
        let range = NSRange(note.startIndex..., in: note)
        guard let match = Self.walkNote?.firstMatch(in: note, range: range),
              let uid = Range(match.range(at: 1), in: note)
        else { return nil }
        return String(note[uid])
    }

    private func startWalk(_ uid: String, at entry: RecordingLog.Entry) async {
        if open == nil {
            open = Open(
                opened: entry.time,
                sentMark: conn.sendCount,
                heardMark: heardCount,
                place: "\(result.name) \(ConsiderScenarioReplay.clock(entry.time))"
            )
            for packet in [lastStatus, lastRoom].compactMap(\.self) {
                await controller.processChunk(Self.gmcpBytes(packet))
            }
        } else {
            if open?.recorded == nil { open?.recorded = .replaced }
            if open?.window.cancelledAt != nil, open?.window.nextWalkAt == nil {
                let mark = open?.sentMark ?? 0
                open?.window.nextWalkAt = conn.sentLines(since: mark).count
            }
        }
        let walkto = lastInput
            .map { entry.time - $0.time < 2 && $0.text.hasPrefix("mapper walkto ") } ?? false
        await controller.fire(.command("mapper \(walkto ? "walkto" : "goto") \(uid)"))
        open?.segments = await mapper.walkSegments.map(\.command)
        open?.resolvedAt = nil
        await reflectEchoes()
    }

    private func feed(_ entry: RecordingLog.Entry) async {
        switch entry.kind {
        case .recv:
            await feedLine(entry.body)
        case .gmcp:
            let walking = await mapper.isWalking
            await controller.processChunk(Self.gmcpBytes(entry.body))
            if walking, await !mapper.isWalking, await mapper.walkEndOwed { open?.window.landedEarly = true }
        case .send:
            noteRecordedSend(entry.body)
        case .input:
            guard entry.body.lowercased() == "mapper stop" else { return }
            if open?.recorded == nil { open?.recorded = .stopped }
            await controller.fire(.command("mapper stop"))
        default:
            return
        }
        await reflectEchoes()
    }

    private func feedLine(_ text: String) async {
        // The old client's markers, reflected: the replay reflects its own.
        let markers = ["{begin running}", "{end running}", "{mapper_wait}"]
        if markers.contains(where: text.contains) { return }
        let shape = WalkAudit.cancelShape(text)
        if let shape, open?.recorded == nil {
            open?.recorded = .failed
            result.failures[shape, default: 0] += 1
        }
        let walking = await mapper.isWalking
        let failed = shape != nil && walking
        await controller.processChunk(Array((text + "\r\n").utf8))
        guard failed, let open, open.window.cancelledAt == nil else { return }
        // From here no segment of this walk may go out, cancelled or not.
        self.open?.window.failedWhileWalking = true
        self.open?.window.cancelledAt = conn.sentLines(since: open.sentMark).count
        self.open?.window.cancelledSegments = open.segments
        if await !mapper.isWalking { result.cancelled += 1 }
    }

    /// The recording's own first segment, to compare routes.
    private func noteRecordedSend(_ command: String) {
        guard let current = open else { return }
        if command == WalkAudit.begin {
            open?.recordedBegun = true
        } else if current.recordedBegun, current.recordedFirst == nil, !command.hasPrefix("echo ") {
            open?.recordedFirst = command
        }
    }

    /// The server's half of `echo`: each marker the replay sent comes back.
    private func reflectEchoes() async {
        while reflectedMark < conn.sendCount {
            let lines = conn.sentLines(since: reflectedMark)
            reflectedMark = conn.sendCount
            for line in lines where line.hasPrefix("echo {") {
                await controller.processChunk(Array((String(line.dropFirst(5)) + "\r\n").utf8))
            }
        }
    }

    private func settle(at time: Double) async {
        guard let current = open else { return }
        let walking = await mapper.isWalking
        if walking {
            open?.resolvedAt = nil
        } else if current.resolvedAt == nil {
            open?.resolvedAt = time
        }
        if let resolvedAt = open?.resolvedAt, time - resolvedAt > Self.tail {
            await close(resolved: true)
        } else if time - current.opened > Self.cap {
            await close(resolved: false)
        }
    }

    private func finish() async {
        guard open != nil else {
            await controller.disconnect()
            return
        }
        if open?.recorded == nil { open?.recorded = .disconnected }
        open?.window.disconnected = true
        await controller.disconnect()
        // The disconnect callbacks run on a task of their own.
        for _ in 0..<50 where await heard(from: open?.heardMark ?? 0).last != WalkAudit.free {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await close(resolved: true, reset: false)
    }

    // MARK: - Judging a window

    private func close(resolved: Bool, reset: Bool = true) async {
        guard var current = open else { return }
        open = nil
        current.window.sent = conn.sentLines(since: current.sentMark)
        current.window.heard = await heard(from: current.heardMark)
        current.window.resolved = resolved
        result.broadcasts += current.window.heard.count
        current.window.paced = current.window.sent.contains { $0.hasPrefix("echo {mapper_wait}") }
        current.window.afterPaced = lastWindowPaced
        lastWindowPaced = current.window.paced
        let recorded = current.recorded ?? .completed
        result.windows[recorded, default: 0] += 1
        if !current.window.sent.contains(WalkAudit.begin) {
            result.noRoute += 1
        } else if current.window.paced {
            result.paced += 1
        } else if resolved {
            result.resolved += 1
        } else {
            result.unresolved += 1
            if WalkAudit.owesEnd(current.window) { result.unresolvedOwingEnd += 1 }
        }
        let violations = WalkAudit.violations(current.window)
        let onRoute = compareRoute(current)
        let route = onRoute == false ? " (off the recorded route)" : ""
        for violation in violations {
            result.violations.append("\(current.place) [\(recorded.rawValue)] \(violation)\(route)")
        }
        let failure = violations.contains { $0.contains("failed move") }
        if !violations.isEmpty, result.traces.count < 10 || failure {
            result.traces.append("\(current.place): sent \(current.window.sent.prefix(16)) "
                + "heard \(current.window.heard) planned \(current.segments)")
        }
        guard reset else { return }
        // Clean for the next window: an end still owed here was judged here.
        await mapper.clearWalk()
        await controller.cancelWaitWalk()
        await controller.endRunningOnDisconnect()
        reflectedMark = conn.sendCount
        heardCount = await heard(from: 0).count
    }

    /// Whether the replay's first segment was the recording's; nil when
    /// either is missing.
    private func compareRoute(_ current: Open) -> Bool? {
        guard let recorded = current.recordedFirst,
              let begin = current.window.sent.firstIndex(of: WalkAudit.begin),
              let replayed = current.window.sent[(begin + 1)...].first(where: { !$0.hasPrefix("echo ") })
        else { return nil }
        result.routeCompared += 1
        if recorded == replayed { result.routeAgreed += 1 }
        return recorded == replayed
    }

    private func heard(from index: Int) async -> [String] {
        let script = "Send(table.concat(heard, '|', \(index + 1)))"
        let effects = await engine.runInPluginEnvironment("com.test.walk-replay", script)
        for case .send(let text) in effects {
            return text.split(separator: "|").map(String.init)
        }
        return []
    }

    /// A GMCP packet as the wire carried it: `IAC SB GMCP <package json> IAC SE`.
    static func gmcpBytes(_ body: String) -> [UInt8] {
        [255, 250, 201] + Array(body.utf8) + [255, 240]
    }
}

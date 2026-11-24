import Foundation
@testable import MudCore
import Testing

/// The scenario replays' own tests (always on): the log reader, both audits
/// on hand-made input that breaks each rule, and both rigs on small logs
/// built from recorded lines.
@Suite("Scenario replay — the harness itself")
struct ScenarioReplayHarnessTests {
    /// One `.log` line: time of day, kind, body.
    struct Row {
        let time: String
        let kind: String
        let body: String

        init(_ time: String, _ kind: String, _ body: String) {
            (self.time, self.kind, self.body) = (time, kind, body)
        }
    }

    /// A `.log` from rows, dated 2026-10-31 UTC.
    static func writeLog(_ rows: [Row]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-scenario-\(UUID().uuidString).log")
        let text = rows.map { (row: Row) -> String in
            let kind = row.kind.padding(toLength: 5, withPad: " ", startingAt: 0)
            return "2026-10-31T\(row.time)Z \(kind) \(row.body)"
        }.joined(separator: "\n")
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("the log reader keeps the kinds asked for, with their times")
    func readerParses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scenario-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        2026-08-21T13:14:09.488+01:00 RECV  You see a kobold.
        not an entry
        2026-10-30T07:10:26.411Z SEND  consider all
        2026-10-30T07:10:27.000Z GAG   [script] hidden
        2026-10-30T07:10:28.250Z RECV    indented

        """.write(to: url, atomically: true, encoding: .utf8)
        var entries: [RecordingLog.Entry] = []
        try RecordingLog.forEach(url, kinds: [.recv, .send]) { entries.append($0); return true }
        #expect(entries.map(\.kind) == [.recv, .send, .recv])
        #expect(entries.map(\.body) == ["You see a kobold.", "consider all", "  indented"])
        let iso = ISO8601DateFormatter()
        let expected = try #require(iso.date(from: "2026-08-21T12:14:09Z")).timeIntervalSince1970 + 0.488
        #expect(abs(entries[0].time - expected) < 0.0001)
        #expect(abs(entries[2].time - entries[1].time - 1.839) < 0.0001)
    }

    @Test("the Consider audit rejects each broken rule")
    func considerAuditRejects() {
        var audit = ConsiderAudit()
        var spite = ConsiderMob(id: 1, name: "A wetland spite", keyword: "spite")
        var ibis = ConsiderMob(id: 2, name: "A radiant ibis", keyword: "ibis")
        audit.observe([spite, ibis], line: nil, at: "t0")
        spite.dead = true
        audit.observe(
            [spite, ibis],
            line: "A wetland spite smoulders as the lightning destroys it!!",
            at: "t1"
        )
        #expect(audit.violations.isEmpty)
        spite.dead = false
        audit.observe([spite, ibis], line: nil, at: "t2")
        ibis.dead = true
        audit.observe([spite, ibis], line: "You feel better.", at: "t3")
        var goat = ConsiderMob(id: 3, name: "A goat", keyword: "goat")
        goat.left = true
        audit.observe([goat], line: "Your speed slows down.", at: "t4")
        var turnus = ConsiderMob(id: 4, name: "Turnus", keyword: "turnus")
        turnus.came = true
        audit.observe([turnus], line: "With a thunderclap, Turnus appears in the room.", at: "t5")
        #expect(audit.violations.count == 4, "\(audit.violations)")
        #expect(audit.violations[0].contains("revived"))
        #expect(audit.violations[1].contains("dead without its kill line"))
        #expect(audit.violations[2].contains("left without its departure line"))
        #expect(audit.violations[3].contains("player's arrival"))
        let before = [ConsiderMob(id: 5, name: "A goat", keyword: "goat")]
        audit.observe(before, line: nil, at: "t6")
        audit.noteLine("A goat ambles north.", before: before, at: "t7")
        #expect(audit.counts.missedDepartures == 1)
    }

    @Test("the walk audit passes a clean walk and rejects each broken rule")
    func walkAuditRejects() {
        let (begin, end, busy, free) = (WalkAudit.begin, WalkAudit.end, WalkAudit.busy, WalkAudit.free)
        let clean = WalkAudit.Window(sent: [begin, "run 2n", end], heard: [busy, free], resolved: true)
        #expect(WalkAudit.violations(clean).isEmpty)
        let cases: [(WalkAudit.Window, String)] = [
            (.init(sent: [begin, begin, end], resolved: true), "began while"),
            (.init(sent: [end]), "no walk to end"),
            (.init(sent: [begin, "run n"], resolved: true), "never sent its end"),
            (
                .init(
                    sent: [begin, "run n", end, "run s"],
                    cancelledAt: 3,
                    cancelledSegments: ["run n", "run s"]
                ),
                "after the move failed"
            ),
            (.init(heard: [busy, busy]), "twice in a row"),
            (.init(sent: [begin, end], heard: [busy], resolved: true), "last heard kinda_busy"),
            (.init(sent: [begin, "run n"], failedWhileWalking: true), "owing its end")
        ]
        for (window, expected) in cases {
            let found = WalkAudit.violations(window)
            #expect(found.count == 1 && found[0].contains(expected), "\(expected): \(found)")
        }
        // A paced walk's end comes later, from its own task: not judged.
        #expect(WalkAudit.violations(.init(sent: [begin, "run n"], resolved: true, paced: true)).isEmpty)
    }

    /// session-20261031-065653, 07:36:51–07:37:59, as its log has it, with
    /// the consider sent as a `SEND` (the list's feature doesn't send).
    @Test("the Consider rig replays the zenith kills: three dead, the ibis left, no violations")
    func considerRig() throws {
        let url = try Self.writeLog([
            Row(
                "07:36:51.766",
                "GMCP",
                #"char.status { "level": 201, "align": -49, "state": 3, "pos": "Standing" }"#
            ),
            Row("07:36:52.000", "GMCP", #"room.info {"num":23681,"name":"r","zone":"zenith","details":""}"#),
            Row(
                "07:37:02.245",
                "GMCP",
                #"room.info { "num": 23684, "name": "Gossamer Mistwillows", "zone": "zenith" }"#
            ),
            Row("07:37:02.300", "SEND", "consider all"),
            Row("07:37:02.625", "RECV", "(R) A wetland spite snickers nervously."),
            Row("07:37:02.625", "RECV", "(R) A red-bellied lieweaver snickers nervously."),
            Row("07:37:02.625", "RECV", "(G) A songweaver snickers nervously."),
            Row("07:37:02.625", "RECV", "(G) A radiant ibis snickers nervously."),
            Row("07:37:03.022", "RECV", "{ consider }"),
            Row("07:37:20.291", "GMCP", #"char.status { "level": 201, "align": -49, "state": 8 }"#),
            Row(
                "07:37:20.683",
                "GMCP",
                #"char.status { "level": 201, "align": -35, "state": 3, "pos": "Standing" }"#
            ),
            Row("07:37:20.688", "RECV", "A wetland spite smoulders as the lightning destroys it!!"),
            Row("07:37:27.614", "RECV", "A radiant ibis flutters south."),
            Row("07:37:50.789", "RECV", "A red-bellied lieweaver smoulders as the lightning destroys it!!"),
            Row("07:37:59.809", "RECV", "A songweaver smoulders as the lightning destroys it!!")
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ConsiderScenarioReplay.replay(url)
        #expect(result.audit.violations.isEmpty, "\(result.audit.violations)")
        #expect(result.audit.counts.deadInMultiMobLists == 3)
        #expect(result.audit.counts.leftMarks == 1)
        #expect(result.audit.counts.verbs == ["flutters": 1])
        // Auto-refresh would have considered on entering each room.
        #expect(result.wouldSend.byReason == ["room.info": 2])
        #expect(result.wouldSend.recordedConsiders == 1)
    }

    /// Standing in room 1, whose only route to 20 is a portal to 14 then
    /// south: two segments.
    private func portalMapper() async throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-walk-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        for json in [
            #"{"num":20,"name":"Target","zone":"z","exits":{"n":14}}"#,
            #"{"num":14,"name":"PortalDest","zone":"z","exits":{"s":20}}"#,
            #"{"num":1,"name":"Start","zone":"z","exits":{}}"#
        ] {
            _ = await mapper.ingest(package: "room.info", json: json)
        }
        _ = await mapper.handleCommand("mapper fullportal {dinv portal use 999} {14}")
        return (mapper, url)
    }

    /// The 2026-10-17 09:35 shape (a multi-segment walk, then a failed
    /// move), on the portal fixture: the replay cancels, ends once, holds
    /// the second segment back even when the portal room then arrives, and
    /// plugins hear busy then free.
    @Test("the walk rig drives the real session: a failed move cancels the walk cleanly")
    func walkRig() async throws {
        let (mapper, db) = try await portalMapper()
        defer { try? FileManager.default.removeItem(at: db) }
        let url = try Self.writeLog([
            Row("09:35:05.000", "GMCP", #"room.info {"num":1,"name":"Start","zone":"z","exits":{}}"#),
            Row("09:35:06.187", "INPUT", "mapper goto 20"),
            Row("09:35:06.253", "NOTE", "Walking to Target [20] — 2 step(s)."),
            Row("09:35:06.253", "SEND", "echo {begin running}"),
            Row("09:35:06.254", "SEND", "dinv portal use 999"),
            Row("09:35:06.467", "RECV", "{begin running}"),
            Row("09:35:06.592", "RECV", "Alas, you cannot go that way."),
            Row(
                "09:35:07.000",
                "GMCP",
                #"room.info {"num":14,"name":"PortalDest","zone":"z","exits":{"s":20}}"#
            ),
            Row("09:35:20.000", "RECV", "[prompt]>")
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WalkScenarioReplay.replay(url, mapper: mapper)
        #expect(result.violations.isEmpty, "\(result.violations)")
        #expect(result.windows == [.failed: 1])
        #expect(result.failures == ["Alas, you cannot go that way.": 1])
        #expect(result.cancelled == 1)
        #expect(result.resolved == 1)
        #expect(result.broadcasts == 2)
        #expect(result.routeAgreed == 1)
    }
}

#if os(macOS)
    /// The corpus run (opt-in, `PROTELES_SCENARIOS=1`, or `=consider` / `=walks`
    /// for one pass): both rigs over every
    /// recording with a log, the report written under
    /// `~/Documents/Proteles/Diagnostics/scenarios/`, and every hard violation
    /// listed. `PROTELES_SCENARIO_SESSIONS` narrows it to some sessions.
    @Suite("Scenario replay — the recordings", .serialized, .enabled(if: ScenarioCorpus.isEnabled))
    struct ScenarioCorpusTests {
        @Test("Consider and walks hold over the corpus")
        func corpus() async throws {
            let clock = ContinuousClock()
            let start = clock.now
            let logs = RecordingLog.corpusLogs()
            let consider = ScenarioCorpus.runs("consider") ? try await ScenarioCorpus.considerAll(logs) : []
            let walks = ScenarioCorpus.runs("walks") ? try await ScenarioCorpus.walkAll(logs) : []
            let report = ScenarioReport.markdown(consider: consider, walks: walks, elapsed: clock.now - start)
            let written = try ScenarioReport.write(report)
            print(report)
            print("scenario: report at \(written.path)")
            let violations = consider.flatMap(\.audit.violations) + walks.flatMap(\.violations)
            let all = written.deletingPathExtension().appendingPathExtension("violations.txt")
            try violations.joined(separator: "\n").write(to: all, atomically: true, encoding: .utf8)
            #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.prefix(20))")
        }
    }
#endif

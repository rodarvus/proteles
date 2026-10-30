import Foundation
@testable import MudCore
import Testing

/// The harness's own tests (always on) — S0a item 7, §5 of the proposal.
@Suite("CorpusReplay — the harness itself")
struct CorpusReplayHarnessTests {
    // Telnet bytes, spelled out rather than imported so the fixture reads as
    // what the wire carried: IAC WILL GMCP, then IAC SB GMCP <payload> IAC SE.
    private static let iac: UInt8 = 255
    private static let will: UInt8 = 251
    private static let sb: UInt8 = 250
    private static let se: UInt8 = 240
    private static let gmcpOption: UInt8 = 201

    /// A three-line recording covering all three tiers: one GMCP packet, one
    /// event tag, one prose line, plus a line that classifies to nothing.
    private func writeSyntheticRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-corpus-replay-\(UUID().uuidString).jsonl")
        let recorder = try SessionRecorder(url: url)
        var bytes: [UInt8] = [Self.iac, Self.will, Self.gmcpOption]
        bytes += [Self.iac, Self.sb, Self.gmcpOption]
        bytes += Array(#"comm.repop { "zone": "zenith" }"#.utf8)
        bytes += [Self.iac, Self.se]
        bytes += Array("You feel safe.\r\n{affoff}259\r\nYou raise a level! You are now level 100.\r\n".utf8)
        try recorder.record(bytes, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        recorder.close()
        return url
    }

    @Test("replay(into:) keeps the pipeline's decoded GMCP")
    func replayKeepsGMCP() throws {
        let url = try writeSyntheticRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let replayer = try SessionReplayer(url: url)
        var pipeline = LinePipeline()
        let output = try replayer.replay(into: &pipeline)
        #expect(output.gmcp.count == 1)
        #expect(output.gmcp.first?.package == "comm.repop")
        #expect(output.gmcp.first?.json.contains("zenith") == true)
        #expect(output.lines.count == 3)
    }

    @Test("A replayed session carries one event per tier, positioned by line")
    func replayClassifiesAllThreeTiers() throws {
        let url = try writeSyntheticRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let replayed = try CorpusReplay.replay(url)
        #expect(replayed.session.lines == 3)
        #expect(replayed.session.gmcp == 1)
        #expect(replayed.session.events == [
            CorpusReplay.Event(
                index: 0, name: "zone_repop", category: "world", source: "gmcp:comm.repop", payload: [:]
            ),
            CorpusReplay.Event(
                index: 1,
                name: "affect_off",
                category: "affect",
                source: "tag:spellups",
                payload: ["spell": "259"]
            ),
            CorpusReplay.Event(
                index: 2, name: "level_up", category: "progression", source: "pattern:level_up", payload: [:]
            )
        ])
        #expect(CorpusReplay.violations(in: replayed).isEmpty)
        #expect(CorpusReplay.usesSpellupTags(replayed))
        #expect(CorpusReplay.summary(replayed.session) == [
            "zone_repop/gmcp": 1, "affect_off/tag": 1, "level_up/pattern": 1
        ])
        // One cue per GMCP and prose event; the tag event has no cue.
        #expect(replayed.cues == ["zone_repop.wav": 1, "level_up.wav": 1])
    }

    /// The invariants must catch a layer that is wrong, not only bless one
    /// that is right: a hand-made session with a dropped tag event, a stray
    /// tag event, a mislabelled category and a missing repop all fail.
    @Test("The invariants reject a session that disagrees with the recognisers")
    func invariantsRejectWrongSessions() {
        let gmcp = [GMCPMessage(package: "comm.repop", json: #"{ "zone": "zenith" }"#)]
        let texts = ["{affoff}259", "Hello there.", "You raise a level! You are now level 100."]
        let wrong = CorpusReplay.Session(name: "wrong", lines: 3, gmcp: 1, events: [
            // index 0: the tag event is missing (dropped)
            CorpusReplay.Event(
                index: 1,
                name: "affect_on",
                category: "affect",
                source: "tag:spellups",
                payload: [:]
            ),
            CorpusReplay.Event(
                index: 2,
                name: "level_up",
                category: "world",
                source: "pattern:level_up",
                payload: [:]
            ),
            CorpusReplay.Event(
                index: 2,
                name: "death",
                category: "combat",
                source: "pattern:death",
                payload: [:]
            )
            // and no zone_repop for the repop packet
        ])
        let replayed = CorpusReplay.Replayed(session: wrong, lineTexts: texts, gmcp: gmcp, cues: [:])
        let violations = CorpusReplay.violations(in: replayed)
        #expect(violations.count == 5, "\(violations)")
        #expect(violations.contains { $0.contains("expected [affect_off] got []") })
        #expect(violations.contains { $0.contains("non-event-tag line") })
        #expect(violations.contains { $0.contains("vocabulary says progression") })
        #expect(violations.contains { $0.contains("death matches no rule") })
        #expect(violations.contains { $0.contains("zone_repop expected 1") })
    }

    @Test("The state pass pins blocks per feed and flags an incomplete block")
    func statePassPinsAndFlags() {
        func line(_ text: String) -> Line {
            Line(id: LineID(0), text: text)
        }
        var clean = StateRecorder()
        let cleanLines = ["{roomchars}", "A mob.", "{/roomchars}", "{exits}[ Exits: north ]"]
        for (index, text) in cleanLines.enumerated() {
            clean.observe(line(text), index: index)
        }
        clean.observe(gmcp: GMCPMessage(package: "room.info", json: "{}"))
        #expect(clean.pin == StateRecorder.Pin(
            seen: ["roomchars", "exits", "room.info"],
            blocks: ["roomchars": 1]
        ))
        #expect(clean.arrivals == ["exits": 1, "room.info": 1])
        #expect(clean.independentArrivals == clean.arrivals)
        #expect(clean.violations(session: "s").isEmpty)

        var broken = StateRecorder()
        for (index, text) in ["{roomchars}", "A mob.", "{roomobjs}", "{/roomobjs}"].enumerated() {
            broken.observe(line(text), index: index)
        }
        #expect(broken.violations(session: "s") == ["s state: incomplete 2: {roomchars} block interrupted"])
    }

    @Test("The documented tag recogniser accepts the corpus shapes and rejects malformed ones")
    func documentedTagRecogniser() {
        #expect(CorpusReplay.documentedTagEvent(for: "{affon}614,1200") == "affect_on")
        #expect(CorpusReplay.documentedTagEvent(for: "{sfail}104,0,2,-1") == "cast_failed")
        #expect(CorpusReplay.documentedTagEvent(for: "{recoff}0") == "recovery_off")
        #expect(CorpusReplay.documentedTagEvent(for: "{skillgain}223,99") == "skill_gain")
        #expect(CorpusReplay.documentedTagEvent(for: "{affon}259") == nil)
        #expect(CorpusReplay.documentedTagEvent(for: "{sfail}72,5,2,-1") == nil)
        #expect(CorpusReplay.documentedTagEvent(for: "{rname}The top of the tower") == nil)
        #expect(CorpusReplay.documentedTagEvent(for: "You feel safe.") == nil)
    }

    @Test("diff reports added and removed events; a baseline round-trips through disk")
    func diffAndBaselineRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-replay-baseline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = CorpusReplay.Event(
            index: 3,
            name: "level_up",
            category: "progression",
            source: "pattern:level_up",
            payload: [:]
        )
        let gone = CorpusReplay.Event(
            index: 5,
            name: "death",
            category: "combat",
            source: "pattern:death",
            payload: [:]
        )
        let new = CorpusReplay.Event(
            index: 7,
            name: "affect_on",
            category: "affect",
            source: "tag:spellups",
            payload: ["spell": "1"]
        )
        let baseline = CorpusReplay.Session(name: "s", lines: 10, gmcp: 0, events: [kept, gone])
        let current = CorpusReplay.Session(name: "s", lines: 10, gmcp: 0, events: [kept, new])

        let diff = CorpusReplay.diff(baseline: baseline, current: current)
        #expect(diff.added == [new])
        #expect(diff.removed == [gone])
        #expect(CorpusReplay.diff(baseline: baseline, current: baseline).isEmpty)

        #expect(CorpusReplay.loadBaseline(named: "s", from: directory) == nil)
        try CorpusReplay.saveBaseline(baseline, to: directory)
        #expect(CorpusReplay.loadBaseline(named: "s", from: directory) == baseline)

        let texts = (0..<10).map { "line \($0)" }
        let report = CorpusReplay.describe(diff, baseline: baseline, current: current, lineTexts: texts)
        #expect(report.contains("s: +1 −1 events"))
        #expect(report.contains("affect_on/tag: 0 → 1"))
        #expect(report.contains("death/pattern: 1 → 0"))
        #expect(report.contains("+ 7 affect_on [tag:spellups]  line 7"))
        #expect(report.contains("− 5 death [pattern:death]  line 5"))
    }

    /// The smallest disabled-path case: the checked-in welcome banner has no
    /// game output, so it must classify to nothing and violate nothing.
    @Test("The welcome banner fixture yields zero events and zero violations")
    func welcomeBannerIsSilent() throws {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/aardwolf-welcome-banner", withExtension: "jsonl"
        ))
        let replayed = try CorpusReplay.replay(url)
        #expect(replayed.session.lines == 24)
        #expect(replayed.session.events.isEmpty)
        #expect(CorpusReplay.violations(in: replayed).isEmpty)
        #expect(!CorpusReplay.usesSpellupTags(replayed))
    }
}

/// Over the local corpus. Opt in with `PROTELES_REPLAY=1`; re-pin with
/// `PROTELES_REPLAY_PIN=1`. Skipped by default and on CI.
///
///     PROTELES_REPLAY=1 swift test --filter CorpusReplay
@Suite("CorpusReplay — invariants over the local corpus", .serialized, .enabled(if: CorpusReplay.isEnabled))
struct CorpusReplayInvariantTests {
    @Test("Every session satisfies the invariants")
    func corpusInvariantsHold() throws {
        let result = try CorpusReplayRun.shared.result()
        try #require(result.sessions > 0, "no recordings found under \(CorpusReplay.corpusDirectory.path)")
        let first = result.violations.prefix(20).joined(separator: "\n")
        #expect(result.violations.isEmpty, "\(result.violations.count) violations; first 20:\n\(first)")
    }
}

@Suite("CorpusReplay — pin and diff", .serialized, .enabled(if: CorpusReplay.isEnabled))
struct CorpusReplayBaselineTests {
    @Test("Every session classifies as its reviewed baseline")
    func corpusMatchesBaseline() throws {
        let result = try CorpusReplayRun.shared.result()
        try #require(result.sessions > 0, "no recordings found under \(CorpusReplay.corpusDirectory.path)")
        let reports = result.diffReports.joined(separator: "\n\n")
        let count = result.diffReports.count
        #expect(
            result.diffReports.isEmpty,
            "\(count) sessions differ (re-pin with PROTELES_REPLAY_PIN=1 after review):\n\n\(reports)"
        )
    }
}

@Suite("CorpusReplay — cue pin and diff", .serialized, .enabled(if: CorpusReplay.isEnabled))
struct CorpusReplayCueBaselineTests {
    @Test("Every session plays the cues of its reviewed baseline")
    func corpusCuesMatchBaseline() throws {
        let result = try CorpusReplayRun.shared.result()
        try #require(result.sessions > 0, "no recordings found under \(CorpusReplay.corpusDirectory.path)")
        let reports = result.cueDiffReports.joined(separator: "\n\n")
        let count = result.cueDiffReports.count
        let rePin = "re-pin with PROTELES_REPLAY_PIN=1 after review"
        #expect(result.cueDiffReports.isEmpty, "\(count) sessions cue differently (\(rePin)):\n\n\(reports)")
    }
}

@Suite("CorpusReplay — state pin and diff", .serialized, .enabled(if: CorpusReplay.isEnabled))
struct CorpusReplayStateBaselineTests {
    @Test("Every session keeps the actionable state of its reviewed baseline")
    func corpusStateMatchesBaseline() throws {
        let result = try CorpusReplayRun.shared.result()
        try #require(result.sessions > 0, "no recordings found under \(CorpusReplay.corpusDirectory.path)")
        let reports = result.stateDiffReports.joined(separator: "\n\n")
        let count = result.stateDiffReports.count
        let rePin = "re-pin with PROTELES_REPLAY_PIN=1 after review"
        #expect(
            result.stateDiffReports.isEmpty,
            "\(count) sessions differ in state (\(rePin)):\n\n\(reports)"
        )
    }
}

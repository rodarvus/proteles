import Foundation
@testable import MudCore
import Testing

@Suite("Diagnostics — performance probe (#75)")
struct PerformanceProbeTests {
    @Test("records only phases over threshold as transcript notes")
    func recordsOnlySlowPhases() {
        let probe = PerformanceProbe()
        let now = Date(timeIntervalSince1970: 1000)
        probe.reset(now: now)
        probe.setMode(.full)

        probe.recordPhase(
            "fast.phase",
            duration: .milliseconds(49),
            events: 12,
            thresholdMS: 50,
            at: now
        )
        #expect(probe.drainPendingNotes().isEmpty)

        probe.recordPhase(
            "slow.phase",
            duration: .milliseconds(50),
            events: 3,
            thresholdMS: 50,
            at: now
        )
        let notes = probe.drainPendingNotes()
        #expect(notes.count == 1)
        #expect(notes[0].contains("perf: slow.phase 50ms events 3"))
    }

    @Test("stall note includes latest slow phase attribution")
    func formatsStallWithLatestSlowPhase() {
        let probe = PerformanceProbe()
        let login = Date(timeIntervalSince1970: 2000)
        probe.reset(now: login)
        probe.setMode(.full)
        probe.stallAttributionWindow = 5
        probe.markInGame(at: login)
        probe.recordPhase(
            "main-output.storage-edit",
            duration: .milliseconds(72),
            events: 8,
            thresholdMS: 50,
            at: login.addingTimeInterval(5)
        )

        let note = probe.stallNote(blockedMS: 123, at: login.addingTimeInterval(6))
        #expect(note.contains("UI stall: main thread blocked ~123ms"))
        #expect(note.contains("login+6.0s"))
        #expect(note.contains("main-output.storage-edit 72ms events 8"))
        #expect(note.contains("startup"))
    }

    @Test("stall note marks old slow phase attribution as stale")
    func formatsStallWithStaleSlowPhase() {
        let probe = PerformanceProbe()
        let login = Date(timeIntervalSince1970: 2100)
        probe.reset(now: login)
        probe.setMode(.full)
        probe.stallAttributionWindow = 5
        probe.markInGame(at: login)
        probe.recordPhase(
            "session.lines.process",
            duration: .milliseconds(111),
            events: 446,
            thresholdMS: 100,
            at: login.addingTimeInterval(1)
        )

        let note = probe.stallNote(blockedMS: 259, at: login.addingTimeInterval(132))
        #expect(note.contains("login+132.0s"))
        #expect(note.contains("last perf phase: stale 131.0s ago"))
        #expect(note.contains("session.lines.process 111ms events 446"))
    }

    @Test("stale stall note includes recent below-threshold phase pressure")
    func staleStallIncludesRecentPressure() {
        let probe = PerformanceProbe()
        let login = Date(timeIntervalSince1970: 2200)
        probe.reset(now: login)
        probe.setMode(.full)
        probe.stallAttributionWindow = 5
        probe.recentPressureWindow = 10
        probe.markInGame(at: login)
        probe.recordPhase(
            "session.gmcp.dispatch",
            duration: .milliseconds(140),
            events: 8,
            thresholdMS: 100,
            at: login.addingTimeInterval(1)
        )
        probe.recordPhase(
            "session.lines.process",
            duration: .milliseconds(28),
            events: 40,
            thresholdMS: 100,
            at: login.addingTimeInterval(129)
        )
        probe.recordPhase(
            "session.lines.script-display",
            duration: .milliseconds(24),
            events: 1,
            thresholdMS: 100,
            at: login.addingTimeInterval(130)
        )

        let note = probe.stallNote(blockedMS: 210, at: login.addingTimeInterval(132))
        #expect(note.contains("last perf phase: stale 131.0s ago"))
        #expect(note.contains("recent perf: last 10s phases 2 slow 0 events 41"))
        #expect(note.contains("max session.lines.process 28ms"))
        #expect(note.contains("session.lines.process x1 max 28ms"))
        #expect(note.contains("session.lines.script-display x1 max 24ms"))
    }

    @Test("stall note reports no recent pressure when attribution was quiet")
    func stallWithoutRecentPressure() {
        let probe = PerformanceProbe()
        let now = Date(timeIntervalSince1970: 2300)
        probe.reset(now: now)
        probe.setMode(.full)

        let note = probe.stallNote(blockedMS: 90, at: now)
        #expect(note.contains("last perf phase: none"))
        #expect(note.contains("recent perf: none in last 10s"))
    }

    @Test("classifies slow phases outside startup as live play")
    func classifiesLivePlay() {
        let probe = PerformanceProbe()
        let login = Date(timeIntervalSince1970: 3000)
        probe.startupWindow = 120
        probe.reset(now: login)
        probe.setMode(.full)
        probe.markInGame(at: login)

        probe.recordPhase(
            "channels.set-text",
            duration: .milliseconds(88),
            events: 400,
            thresholdMS: 50,
            at: login.addingTimeInterval(240)
        )

        let note = probe.drainPendingNotes().first ?? ""
        #expect(note.contains("login+240.0s"))
        #expect(note.contains("live"))
    }

    @Test("summary aggregates counts without recording event text")
    func summaryDoesNotLeakEventText() throws {
        let probe = PerformanceProbe()
        let now = Date(timeIntervalSince1970: 4000)
        probe.reset(now: now)
        probe.setMode(.full)
        probe.recordPhase(
            "session.lines.process",
            duration: .milliseconds(10),
            events: 99,
            thresholdMS: 100,
            at: now
        )
        probe.recordPhase(
            "session.gmcp.dispatch",
            duration: .milliseconds(130),
            events: 4,
            thresholdMS: 100,
            at: now
        )

        let summary = try #require(probe.drainSummary(now: now.addingTimeInterval(30)))
        let formatted = probe.format(summary)
        #expect(formatted.contains("phases 2"))
        #expect(formatted.contains("slow 1"))
        #expect(formatted.contains("session.gmcp.dispatch 130ms"))
        #expect(!formatted.contains("secret line"))
    }

    @Test("burst summary records counts only above threshold")
    func burstSummaryRecordsCountsOnly() {
        let probe = PerformanceProbe()
        let now = Date(timeIntervalSince1970: 4500)
        probe.reset(now: now)
        probe.setMode(.full)
        probe.markInGame(at: now)

        probe.recordEventSummary(
            "session.lines.batch",
            events: 49,
            fields: [("displayed", 20), ("gagged", 29)],
            thresholdEvents: 50
        )
        #expect(probe.drainPendingNotes().isEmpty)

        probe.recordEventSummary(
            "session.lines.batch",
            events: 50,
            fields: [("displayed", 20), ("gagged", 30)],
            thresholdEvents: 50
        )

        let note = probe.drainPendingNotes().first ?? ""
        #expect(note.contains("perf-burst: session.lines.batch events 50"))
        #expect(note.contains("displayed 20 gagged 30"))
        #expect(!note.contains("secret line"))
    }

    @Test("stall note reports missing login marker without guessing")
    func stallWithoutLoginMarker() {
        let probe = PerformanceProbe()
        let now = Date(timeIntervalSince1970: 5000)
        probe.reset(now: now)

        let note = probe.stallNote(blockedMS: 90, at: now)
        #expect(note.contains("login unknown"))
        #expect(note.contains("last perf phase: none"))
    }

    @Test("stall-only mode suppresses attribution notes and summaries")
    func stallOnlySuppressesAttribution() {
        let probe = PerformanceProbe()
        let now = Date(timeIntervalSince1970: 6000)
        probe.reset(now: now)
        probe.setMode(.stallOnly)
        probe.recordPhase(
            "session.lines.process",
            duration: .milliseconds(250),
            events: 10,
            thresholdMS: 100,
            at: now
        )
        probe.recordEventSummary(
            "session.lines.batch",
            events: 100,
            fields: [("displayed", 50), ("gagged", 50)],
            thresholdEvents: 50
        )

        #expect(probe.recordsStalls)
        #expect(!probe.recordsAttribution)
        #expect(probe.drainPendingNotes().isEmpty)
        #expect(probe.drainSummary(now: now.addingTimeInterval(30)) == nil)
    }

    @Test("off mode suppresses stall notes and attribution")
    func offSuppressesAllDiagnostics() {
        let probe = PerformanceProbe()
        probe.setMode(.off)

        #expect(!probe.recordsStalls)
        #expect(!probe.recordsAttribution)
    }
}

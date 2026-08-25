import Foundation
@testable import MudCore
import Testing

/// Build provenance in the transcript — the field whose absence made three days
/// of performance comparison invalid, because Release and Debug both reported
/// `0.8.8` and Debug is 2.30x slower.
@Suite("BuildInfo — which build produced this recording")
struct BuildInfoTests {
    @Test("Configuration is compile-time, so it cannot disagree with the binary")
    func configurationMatchesBinary() {
        #if DEBUG
            #expect(BuildInfo.currentConfiguration == "Debug")
        #else
            #expect(BuildInfo.currentConfiguration == "Release")
        #endif
    }

    @Test("A stamped build reports version, build, configuration, commit and cleanliness")
    func stampedLine() {
        let info = BuildInfo(
            configuration: "Release",
            version: "0.8.8",
            build: "56",
            commit: "43bd3dcd",
            dirty: false
        )
        #expect(info.transcriptLine == "0.8.8 (56) Release 43bd3dcd clean")
    }

    @Test("A dirty tree is reported as such")
    func dirtyLine() {
        let info = BuildInfo(
            configuration: "Debug",
            version: "0.8.8",
            build: "56",
            commit: "43bd3dcd",
            dirty: true
        )
        #expect(info.transcriptLine == "0.8.8 (56) Debug 43bd3dcd dirty")
    }

    /// An unstamped build must say so rather than look clean — silence here is
    /// what caused the original misdiagnosis.
    @Test("An unstamped build is visibly unstamped, not silently clean")
    func unstampedIsVisible() {
        let info = BuildInfo(configuration: "Release", version: "0.8.8", build: "56")
        #expect(info.transcriptLine == "0.8.8 (56) Release (unstamped)")
        #expect(!info.transcriptLine.contains("clean"))
    }

    /// A test host has no version keys; reading must degrade rather than crash.
    @Test("Missing bundle keys degrade to placeholders")
    func missingKeysDegrade() {
        let info = BuildInfo.current(bundle: Bundle(for: TestMarker.self))
        #expect(!info.configuration.isEmpty)
        #expect(!info.version.isEmpty)
        #expect(!info.transcriptLine.isEmpty)
    }

    private final class TestMarker {}
}

/// Burst measurement: many small costs at once, which every existing probe is
/// blind to because they all threshold on a single slow thing.
@Suite("BurstTracker — a burst measured as one unit")
struct BurstTrackerTests {
    private let t0 = ContinuousClock.now

    @Test("Lines within the gap form one burst, reported on the next burst's arrival")
    func linesWithinGapFormOneBurst() {
        var tracker = BurstTracker()
        // Nine lines 5ms apart — a kill burst.
        for index in 0..<9 {
            let note = tracker.noteDisplayedLine(at: t0 + .milliseconds(index * 5))
            #expect(note == nil, "burst must not close mid-run (line \(index))")
        }
        // A line after the gap closes the previous burst.
        let closed = tracker.noteDisplayedLine(at: t0 + .milliseconds(500))
        #expect(closed?.hasPrefix("burst: 9 lines ") == true, "\(closed ?? "nil")")
    }

    @Test("A gap longer than the threshold separates bursts")
    func gapSeparatesBursts() {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        let closed = tracker.noteDisplayedLine(at: t0 + .milliseconds(101))
        #expect(closed?.hasPrefix("burst: 1 line ") == true, "\(closed ?? "nil")")
    }

    @Test("The reported span covers first to last line of the burst")
    func spanCoversTheBurst() {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(40))
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(80))
        let note = tracker.flush()
        #expect(note?.contains("3 lines 80ms") == true, "\(note ?? "nil")")
    }

    /// The point of §3: a regression should name itself rather than be inferred
    /// from reading code. Phases are ranked by cost so the dominant one leads.
    @Test("Phase totals accumulate across the burst and are ranked by cost")
    func phaseBreakdownRanksByCost() throws {
        var tracker = BurstTracker()
        for index in 0..<9 {
            _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(index * 5))
            tracker.accumulate(phase: "session.lines.script-engine", durationMS: 40)
            tracker.accumulate(phase: "session.lines.display", durationMS: 12)
            tracker.accumulate(phase: "session.lines.semantic", durationMS: 0)
        }
        let note = tracker.flush()
        let text = try #require(note)
        #expect(text.contains("lines.script-engine 360ms"), "\(text)")
        #expect(text.contains("lines.display 108ms"), "\(text)")
        // Below the floor: contributes nothing, so it is not named — which is
        // exactly the signal that a suspected culprit is innocent.
        #expect(!text.contains("semantic"), "\(text)")
        // Ranked, dominant first.
        let engineAt = try #require(text.range(of: "script-engine"))
        let displayAt = try #require(text.range(of: "lines.display"))
        #expect(engineAt.lowerBound < displayAt.lowerBound, "\(text)")
    }

    @Test("Phases accumulated with no open burst are dropped, not leaked forward")
    func noLeakBetweenBursts() {
        var tracker = BurstTracker()
        tracker.accumulate(phase: "session.lines.display", durationMS: 999)
        _ = tracker.noteDisplayedLine(at: t0)
        let note = tracker.flush()
        #expect(note?.contains("999ms") == false, "\(note ?? "nil")")
    }

    @Test("flush on an idle tracker reports nothing")
    func flushIdleIsSilent() {
        var tracker = BurstTracker()
        #expect(tracker.flush() == nil)
    }

    @Test("The breakdown is capped so the note stays one line")
    func breakdownIsCapped() throws {
        var tracker = BurstTracker()
        tracker.maxPhasesReported = 3
        _ = tracker.noteDisplayedLine(at: t0)
        for index in 0..<10 {
            tracker.accumulate(phase: "session.phase\(index)", durationMS: 10 + index)
        }
        let flushed = tracker.flush()
        let text = try #require(flushed)
        #expect(text.components(separatedBy: " · ").count == 3, "\(text)")
    }
}

/// The stated constraint: this must not cost anything outside Full attribution.
@Suite("Burst instrumentation — cost", .serialized)
struct BurstInstrumentationCostTests {
    /// Outside `.full` the probe must not even open a burst, so the per-line
    /// call is a mode check and a return.
    @Test("Nothing is tracked outside Full attribution")
    func offOutsideFullAttribution() {
        let probe = PerformanceProbe.shared
        probe.setMode(.stallOnly)
        defer { probe.setMode(.stallOnly) }
        for _ in 0..<1000 {
            probe.noteDisplayedLine()
        }
        probe.flushBurst()
        #expect(probe.drainPendingNotes().isEmpty, "stallOnly must produce no burst notes")

        probe.setMode(.off)
        for _ in 0..<1000 {
            probe.noteDisplayedLine()
        }
        probe.flushBurst()
        #expect(probe.drainPendingNotes().isEmpty, "off must produce no burst notes")
    }

    /// Under `.full` a burst produces exactly one note, not one per line — the
    /// difference between a usable recording and a flood.
    @Test("A burst produces one note, not one per line")
    func oneNotePerBurst() {
        let probe = PerformanceProbe.shared
        probe.setMode(.full)
        defer { probe.setMode(.stallOnly) }
        _ = probe.drainPendingNotes()
        let start = ContinuousClock.now
        for index in 0..<9 {
            probe.noteDisplayedLine(at: start + .milliseconds(index * 5))
        }
        probe.flushBurst()
        let notes = probe.drainPendingNotes().filter { $0.hasPrefix("burst:") }
        #expect(notes.count == 1, "\(notes)")
        #expect(notes.first?.contains("9 lines") == true, "\(notes)")
    }
}

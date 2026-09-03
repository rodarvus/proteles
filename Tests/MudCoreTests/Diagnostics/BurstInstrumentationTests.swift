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
            #expect(note.isEmpty, "burst must not close mid-run (line \(index))")
        }
        // A line after the gap closes the previous burst.
        let closed = tracker.noteDisplayedLine(at: t0 + .milliseconds(500))
        #expect(closed.first?.hasPrefix("burst: 9 lines ") == true, "\(closed)")
    }

    @Test("A gap longer than the threshold separates bursts")
    func gapSeparatesBursts() {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        let closed = tracker.noteDisplayedLine(at: t0 + .milliseconds(101))
        #expect(closed.first?.hasPrefix("burst: 1 line ") == true, "\(closed)")
    }

    @Test("The reported span covers first to last line of the burst")
    func spanCoversTheBurst() {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(40))
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(80))
        tracker.notePaint(at: t0 + .milliseconds(80))
        let note = tracker.flush()
        #expect(note.first?.contains("3 lines 80ms") == true, "\(note)")
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
        let text = try #require(note.first)
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

    /// The correction that mattered: the span must end at the **paint**, not at
    /// the last append. Measured on a real session, near-kill append span was
    /// 1ms p50 while paint latency was 468ms — so an append-ended span answers
    /// "how fast did we ingest", which is not the question.
    @Test("The span ends at the paint, not the last append")
    func spanEndsAtPaint() throws {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(3))
        // Appends finish in 3ms; the paint lands 400ms later.
        tracker.notePaint(at: t0 + .milliseconds(400))
        let flushed = tracker.flush()
        let text = try #require(flushed.first)
        #expect(text.hasPrefix("burst: 2 lines 400ms"), "\(text)")
        #expect(!text.contains("unpainted"), "\(text)")
    }

    /// A single line that took a long time to paint is a real signal. Before
    /// this correction it reported `1 line 0ms`, because append-to-append is
    /// trivially zero — and single-line bursts were the majority.
    @Test("A single-line burst reports its paint latency, not zero")
    func singleLineReportsPaintLatency() throws {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        tracker.notePaint(at: t0 + .milliseconds(120))
        let flushed = tracker.flush()
        let text = try #require(flushed.first)
        #expect(text.hasPrefix("burst: 1 line 120ms"), "\(text)")
    }

    /// With no renderer attached the span falls back to appends and says so,
    /// rather than silently reporting a number that means something else.
    @Test("An unpainted burst is marked, not silently mis-reported")
    func unpaintedIsMarked() throws {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(5))
        let flushed = tracker.flush()
        let text = try #require(flushed.first)
        #expect(text.contains("(unpainted)"), "\(text)")
    }

    /// A paint arriving while nothing is open belongs to no burst.
    @Test("A paint during idle does not attach to the next burst")
    func idlePaintDoesNotLeak() throws {
        var tracker = BurstTracker()
        tracker.notePaint(at: t0)
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(500))
        let flushed = tracker.flush()
        let text = try #require(flushed.first)
        #expect(text.contains("(unpainted)"), "\(text)")
    }

    @Test("Phases accumulated with no open burst are dropped, not leaked forward")
    func noLeakBetweenBursts() {
        var tracker = BurstTracker()
        tracker.accumulate(phase: "session.lines.display", durationMS: 999)
        _ = tracker.noteDisplayedLine(at: t0)
        let note = tracker.flush()
        #expect(note.first?.contains("999ms") == false, "\(note)")
    }

    @Test("flush on an idle tracker reports nothing")
    func flushIdleIsSilent() {
        var tracker = BurstTracker()
        #expect(tracker.flush().isEmpty)
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
        let text = try #require(flushed.first)
        #expect(text.components(separatedBy: " · ").count == 3, "\(text)")
    }

    // MARK: - Attribution (PER_PLUGIN_ATTRIBUTION_PROPOSAL.md §2.2)

    /// The question #86 could not answer: *which* plugin. Attributed samples
    /// are ranked on their own line, so the answer reads off the transcript.
    @Test("Attributed phases produce a second burst-plugins line, ranked by cost")
    func attributedPhasesGetTheirOwnLine() throws {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        tracker.accumulate(phase: "session.script.lua.plugin", durationMS: 40, attribution: "dinv")
        tracker.accumulate(phase: "session.script.lua.plugin", durationMS: 380, attribution: "leveldb")
        tracker.accumulate(phase: "session.script.lua.plugin", durationMS: 20, attribution: "dinv")
        let flushed = tracker.flush()
        #expect(flushed.count == 2, "\(flushed)")
        let plugins = try #require(flushed.last)
        #expect(
            plugins == "burst-plugins: script.lua.plugin[leveldb] 380ms · script.lua.plugin[dinv] 60ms",
            "\(plugins)"
        )
    }

    /// The aggregate stays the aggregate: attribution adds a line, it never
    /// changes the one two weeks of corpus parsers were written against.
    @Test("The burst line is identical with and without attribution")
    func burstLineUnchangedByAttribution() {
        var plain = BurstTracker()
        _ = plain.noteDisplayedLine(at: t0)
        plain.accumulate(phase: "session.script.lua.plugin", durationMS: 400)
        plain.accumulate(phase: "session.lines.display", durationMS: 12)
        plain.notePaint(at: t0 + .milliseconds(450))

        var attributed = BurstTracker()
        _ = attributed.noteDisplayedLine(at: t0)
        attributed.accumulate(phase: "session.script.lua.plugin", durationMS: 400, attribution: "leveldb")
        attributed.accumulate(phase: "session.lines.display", durationMS: 12)
        attributed.notePaint(at: t0 + .milliseconds(450))

        let plainNotes = plain.flush()
        let attributedNotes = attributed.flush()
        #expect(plainNotes.count == 1, "\(plainNotes)")
        #expect(attributedNotes.count == 2, "\(attributedNotes)")
        #expect(plainNotes.first == attributedNotes.first, "\(plainNotes) vs \(attributedNotes)")
    }

    @Test("Attributed totals below the floor are not named, and reset between bursts")
    func attributionFloorAndReset() {
        var tracker = BurstTracker()
        _ = tracker.noteDisplayedLine(at: t0)
        tracker.accumulate(phase: "session.script.lua.plugin", durationMS: 0, attribution: "dinv")
        #expect(tracker.flush().count == 1)
        _ = tracker.noteDisplayedLine(at: t0 + .milliseconds(500))
        tracker.accumulate(phase: "session.script.lua.plugin", durationMS: 5, attribution: "leveldb")
        let second = tracker.flush()
        #expect(second.last?.contains("[leveldb] 5ms") == true, "\(second)")
        #expect(second.last?.contains("dinv") == false, "\(second)")
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

    // MARK: - End to end through the engine (PER_PLUGIN_ATTRIBUTION_PROPOSAL.md §5.3)

    // Each of these gives its engine a private probe. The process-wide one is
    // shared with every session test running in parallel, any of which may
    // `flushBurst()` and drain a burst mid-test — which is exactly what
    // happened on the first full-suite run.

    /// A script that takes long enough to clear the 1 ms burst floor on any
    /// machine (tens of milliseconds here), while staying far below the 50 ms
    /// `perf:` threshold's worst case mattering — the burst line is the assert.
    private static let slowBody = "local s = 0 for i = 1, 1500000 do s = s + i end"

    private static let slowPlugin = """
    <muclient><plugin id="com.proteles.test.slow" name="Slow Plugin"/>
    <triggers>
    <trigger enabled="y" match="^slow trigger$" regexp="y" script="slow_fn" sequence="100"/>
    </triggers>
    <aliases>
    <alias match="^slow alias$" enabled="y" regexp="y" send_to="12" script="slow_fn"/>
    </aliases>
    <script><![CDATA[
    function slow_fn() \(slowBody) end
    function OnPluginInstall()
      AddTimer("slow", 0, 0, 1, "", timer_flag.Enabled + timer_flag.OneShot, "slow_fn")
    end
    ]]></script></muclient>
    """

    /// Runs `body` inside an open burst under full attribution, on a probe
    /// private to `engine`, and returns the burst notes it produced.
    private func burstNotes(
        on engine: ScriptEngine,
        _ body: () async throws -> Void
    ) async throws -> [String] {
        let probe = PerformanceProbe()
        await engine.useProbe(probe)
        probe.setMode(.full)
        probe.noteDisplayedLine()
        try await body()
        probe.flushBurst()
        return probe.drainPendingNotes().filter { $0.hasPrefix("burst") }
    }

    @Test("A plugin trigger's script is attributed to the plugin by name")
    func pluginTriggerIsAttributed() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: Self.slowPlugin))
        let notes = try await burstNotes(on: engine) {
            _ = await engine.process(line: "slow trigger")
        }
        let plugins = try #require(notes.first { $0.hasPrefix("burst-plugins:") }, "\(notes)")
        #expect(plugins.contains("script.lua.plugin[Slow Plugin]"), "\(plugins)")
        #expect(plugins.contains("script.trigger-script.plugin[Slow Plugin]"), "\(plugins)")
    }

    @Test("Alias and timer scripts carry the plugin's name too")
    func aliasAndTimerAreAttributed() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: Self.slowPlugin))
        let aliasNotes = try await burstNotes(on: engine) {
            _ = await engine.expandInput("slow alias")
        }
        #expect(
            aliasNotes.last?.contains("script.lua.plugin[Slow Plugin]") == true,
            "alias: \(aliasNotes)"
        )
        let timerNotes = try await burstNotes(on: engine) {
            _ = await engine.fireDueTimers(at: Date().addingTimeInterval(5))
        }
        #expect(
            timerNotes.last?.contains("script.lua.plugin[Slow Plugin]") == true,
            "timer: \(timerNotes)"
        )
    }

    /// A user script has no owner, so nothing to attribute it to: its phase is
    /// `lua.user`, the burst line is the only line, and no plugin is blamed.
    @Test("A user script is not attributed to anyone")
    func userScriptIsNotAttributed() async throws {
        let engine = try ScriptEngine()
        try await engine.addTimer(
            MudTimer(schedule: .after(1), action: .script(Self.slowBody)),
            now: Date(timeIntervalSince1970: 0)
        )
        let notes = try await burstNotes(on: engine) {
            _ = await engine.fireDueTimers(at: Date(timeIntervalSince1970: 1))
        }
        #expect(notes.count == 1, "\(notes)")
        #expect(notes.first?.contains("script.lua.user") == true, "\(notes)")
        #expect(!notes.contains { $0.hasPrefix("burst-plugins:") }, "\(notes)")
    }
}

import Foundation

/// Measures a *burst* of displayed output as one unit
/// (`docs/plans/BURST_INSTRUMENTATION_PROPOSAL.md` §2/§3).
///
/// ## Why the existing probes could not answer this
///
/// Everything else here is built to catch **one slow thing**:
/// ``PerformanceProbe/measure(_:events:thresholdMS:_:)`` emits only above a
/// threshold (50 ms in the line path), and the output view samples per render
/// flush. But the failure mode that matters is **many small things at once** —
/// a kill emits 7–9 displayed lines in a single packet, and a few milliseconds
/// added to each of them is both clearly felt and completely invisible to a
/// 50 ms threshold.
///
/// The near-kill figures previously used in this repo were produced by
/// hand-bucketing render samples "within 30 lines of an experience-gain line" —
/// a reconstruction that depended on someone's script and only ever found the
/// bursts they thought to look for. This measures bursts directly.
///
/// ## What a burst is
///
/// A run of displayed lines with no idle gap between them. Detection is purely
/// by **timing** — no game text is parsed, so a kill is simply the most common
/// burst rather than a special case, and combat, room entry, `look` output and
/// any future burst shape are all covered by the same measurement.
///
/// A burst closes when the next displayed line arrives after
/// ``gapThreshold``, or when the session ends. Closing on the *next* line
/// avoids needing a timer; the note carries its own timings, so nothing is lost
/// by emitting it slightly late.
///
/// Active only under ``PerformanceProbe/Mode/full``; the caller enforces that.
struct BurstTracker {
    /// Idle gap that ends a burst. Below this, lines belong together.
    /// Proposed and approved at 100 ms: low enough that separate events stay
    /// separate, high enough that one slow burst is not split in two.
    var gapThreshold: Duration = .milliseconds(100)

    /// Most phases kept in a burst's breakdown, so the note stays one line.
    var maxPhasesReported = 12
    /// Phases below this contribute time but are not named individually.
    var phaseFloorMS = 1

    private var lineCount = 0
    private var startedAt: ContinuousClock.Instant?
    private var lastLineAt: ContinuousClock.Instant?
    /// When the renderer last finished painting while this burst was open.
    ///
    /// The burst's span ends **here**, not at the last append. Appending is
    /// near-instant — a 35-line burst appends in ~31 ms — while the player
    /// waits for the *paint*, which happens afterwards in the render
    /// coalescer. Measured on a real session: near-kill append span 1 ms p50
    /// against 468 ms paint. Ending the span at append answers "how fast did we
    /// ingest", which is not the question anyone was asking.
    private var lastPaintAt: ContinuousClock.Instant?
    private var phaseTotals: [String: Int] = [:]

    /// True while a burst is open.
    var isOpen: Bool {
        startedAt != nil
    }

    /// Record a displayed line. Returns the completed burst's note when this
    /// line's arrival *ended* the previous burst, otherwise `nil`.
    mutating func noteDisplayedLine(at now: ContinuousClock.Instant) -> String? {
        var finished: String?
        if let last = lastLineAt, now - last > gapThreshold {
            finished = closedNote(endingAt: last)
        }
        if startedAt == nil {
            startedAt = now
            lineCount = 0
            lastPaintAt = nil
            phaseTotals.removeAll(keepingCapacity: true)
        }
        lineCount += 1
        lastLineAt = now
        return finished
    }

    /// Record that the renderer finished a paint. Only meaningful while a burst
    /// is open; a paint during idle belongs to no burst.
    mutating func notePaint(at now: ContinuousClock.Instant) {
        guard isOpen else { return }
        lastPaintAt = now
    }

    /// Add a measured phase to the open burst. Cheap by construction: one
    /// dictionary add, no formatting until the burst closes.
    mutating func accumulate(phase: String, durationMS: Int) {
        guard isOpen else { return }
        phaseTotals[phase, default: 0] += durationMS
    }

    /// Close an open burst and return its note — for session end, where there
    /// is no "next line" to trigger the close.
    mutating func flush() -> String? {
        guard let last = lastLineAt else { return nil }
        return closedNote(endingAt: last)
    }

    /// Format and reset. A single-line burst is still reported: one line taking
    /// a long time is a real signal, just a different one.
    private mutating func closedNote(endingAt end: ContinuousClock.Instant) -> String? {
        guard let start = startedAt else { return nil }
        // Prefer the paint. Fall back to the last append only when no paint was
        // observed while the burst was open (diagnostics on, no renderer
        // attached — a headless test, or the Help window).
        let painted = lastPaintAt.map { $0 > start ? $0 : end }
        let spanMS = max(0, Int(((painted ?? end) - start) / .milliseconds(1)))
        let lines = lineCount
        let phases = phaseTotals
        let sawPaint = lastPaintAt != nil
        startedAt = nil
        lastLineAt = nil
        lastPaintAt = nil
        lineCount = 0
        phaseTotals.removeAll(keepingCapacity: true)

        var note = "burst: \(lines) line\(lines == 1 ? "" : "s") "
            + "\(spanMS)ms\(sawPaint ? "" : " (unpainted)")"
        let ranked = phases
            .filter { $0.value >= phaseFloorMS }
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .prefix(maxPhasesReported)
        if !ranked.isEmpty {
            let breakdown = ranked
                .map { "\(Self.shortPhase($0.key)) \($0.value)ms" }
                .joined(separator: " · ")
            note += " | \(breakdown)"
        }
        return note
    }

    /// Trim the common `session.` prefix so a breakdown fits one line.
    static func shortPhase(_ phase: String) -> String {
        phase.hasPrefix("session.") ? String(phase.dropFirst("session.".count)) : phase
    }
}

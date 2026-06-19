import MudCore
import MudOutputView_macOS
import SwiftUI

/// Perf diagnostics: the main-thread stall watchdog, the slow-frame probe,
/// the periodic render-health note, and their small reference-type holders.
/// Split from `ContentView.swift` for the file-length budget (and because
/// these are instruments, not UI).
extension ContentView {
    /// A ~50ms MainActor heartbeat; a late wake means the UI thread was
    /// blocked that long, logged to the transcript so perf hitches are
    /// visible in a recording. Log when a wake overruns its budget by
    /// >80 ms. Cheap (one wake/50ms; logs only on a real stall).
    func monitorMainThreadStalls() async {
        let beat = Duration.milliseconds(50)
        let budget = beat / .milliseconds(1) / 1000 // seconds
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: beat)
            let now = Date()
            let overrun = now.timeIntervalSince(last) - budget
            last = now
            if overrun > 0.08 {
                let note = PerformanceProbe.shared.stallNote(
                    blockedMS: Int(overrun * 1000),
                    at: now
                )
                await session.recordNote(note)
            }
        }
    }

    /// Drain thresholded perf notes into the transcript. The probe never writes
    /// to the transcript directly, so transcript I/O can be measured without
    /// recursively producing a note per transcript write.
    func performanceProbeLoop() async {
        var nextSummary = Date().addingTimeInterval(30)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            for note in PerformanceProbe.shared.drainPendingNotes() {
                await session.recordNote(note)
            }
            let now = Date()
            guard now >= nextSummary else { continue }
            nextSummary = now.addingTimeInterval(30)
            if let summary = PerformanceProbe.shared.drainSummary(now: now) {
                await session.recordNote(PerformanceProbe.shared.format(summary))
            }
        }
    }

    /// Perf probe: log only frames that overran a 60 fps paint budget *or*
    /// showed a high arrival→paint latency, so the transcript reveals jagged
    /// hitches without noise. Since the 2026-06-12 hangs the note carries the
    /// live **document size** — the datum that separates "eviction broken in
    /// the field" (unbounded growth) from "fixed-size document degrading".
    /// Every frame also lands in ``renderStats`` for the health loop.
    func logSlowFrame(_ stats: RenderFrameStats) {
        renderStats.latest = stats
        let flushMS = stats.flushDuration / .milliseconds(1)
        let latencyMS = stats.maxArrivalLatency * 1000
        guard flushMS > 12 || latencyMS > 120 else { return }
        let note = "render: \(stats.appendedLines) line(s) "
            + "flush \(Int(flushMS))ms arrival→paint \(Int(latencyMS))ms "
            + "doc \(stats.documentLines) lines/\(stats.documentUTF16Length) u16"
        Task { await session.recordNote(note) }
    }

    /// Every 10 minutes, one transcript line with the live document size —
    /// so a session whose flushes never cross the slow threshold still
    /// proves whether the rendered document stayed capped (#65 follow-up).
    func renderHealthLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(600))
            guard let stats = renderStats.latest else { continue }
            let flushMS = stats.flushDuration / .milliseconds(1)
            await session.recordNote(
                "render-health: doc \(stats.documentLines) lines/"
                    + "\(stats.documentUTF16Length) u16, last flush \(Int(flushMS))ms"
            )
        }
    }
}

/// Latest render-frame stats, held by reference so per-flush writes don't
/// invalidate ``ContentView`` (the #64 lesson: never put per-event data in
/// root view state).
@MainActor
final class RenderStatsBox {
    var latest: RenderFrameStats?
}

/// A small bounded ring of recent output lines (plain text) — the word source
/// for Tab completion. A reference type so the scrollback subscription can
/// append without triggering a SwiftUI re-render of ``ContentView``.
@MainActor
final class RecentLineBuffer {
    private var lines: [String] = []
    private let capacity: Int

    init(capacity: Int = 250) {
        self.capacity = capacity
    }

    func append(_ text: String) {
        lines.append(text)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    /// Oldest-first, as ``InputCompletion/harvestWords`` expects.
    var snapshot: [String] {
        lines
    }
}

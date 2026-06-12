#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    /// #65 soak bench — NOT part of the normal suite. Run with:
    ///
    ///     PROTELES_BENCH=1 swift test --filter DocumentSizeSoakBench
    ///
    /// Reproduces the 2026-06-12 six-hour hang's mechanism in minutes: drives
    /// a real `NSTextView` through the production ``RenderCoordinator`` at
    /// several scrollback caps, fills each to its cap (so eviction is active,
    /// exactly like the field session that sat at the 50k default), then
    /// probes with combat-paced bursts and reports per-flush latency by
    /// document size. The field evidence said flush cost grows with the
    /// document (13 ms fresh → 308 ms at ~50k → 100% CPU); this measures the
    /// curve and validates the chosen cap + scroll fix hold it flat.
    @Suite("DocumentSizeSoakBench (#65)", .serialized, .enabled(if: soakBenchEnabled))
    @MainActor
    struct DocumentSizeSoakBenchTests {
        @Test("flush latency by document size (5k/10k/25k/50k, eviction active)")
        func flushLatencyByDocumentSize() async throws {
            var report: [String] = []
            for cap in [5000, 10000, 25000, 50000] {
                let stats = try await probe(cap: cap)
                report.append(stats)
                print("SOAK \(stats)")
            }
            print("SOAK ===== summary =====")
            for line in report {
                print("SOAK \(line)")
            }
        }

        /// Fill a store to `cap`, settle, then probe with combat-shaped
        /// bursts; returns the probe's flush-latency stats.
        private func probe(cap: Int) async throws -> String {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            let scrollView = NSTextView.scrollableTextView()
            guard let textView = scrollView.documentView as? NSTextView else {
                Issue.record("no NSTextView from scrollableTextView")
                return "cap \(cap): SETUP FAILED"
            }
            textView.isEditable = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView = scrollView

            let store = ScrollbackStore(maxLines: cap)
            let coordinator = RenderCoordinator(
                textView: textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(16)
            )
            let fillCollector = FlushCollector()
            coordinator.onFrameFlush = { stats in fillCollector.record(stats.flushDuration) }
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            // Fill fast in big bursts (few flushes, each huge — not what we
            // measure; we just need the document AT the cap).
            for index in 0..<cap {
                await store.append(line(index))
                if index % 2000 == 1999 { // let the ticker drain in chunks
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
            try await Task.sleep(for: .milliseconds(300)) // settle

            // Probe: combat-shaped bursts (20 lines / ~8 ms ≈ a heavy fight),
            // evicting at the head the whole time (we're at cap).
            let probeCollector = FlushCollector()
            coordinator.onFrameFlush = { stats in probeCollector.record(stats.flushDuration) }
            for index in 0..<2000 {
                await store.append(line(cap + index))
                if index % 20 == 19 {
                    try await Task.sleep(for: .milliseconds(8))
                }
            }
            try await Task.sleep(for: .milliseconds(200))

            var samples = probeCollector.snapshot().sorted()
            if samples.isEmpty { samples = [0] }
            let p50 = samples[Int(Double(samples.count - 1) * 0.5)]
            let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
            let max = samples.last ?? 0
            let format = "cap %6d: flushes %4d  P50 %7.2fms  P95 %7.2fms  MAX %7.2fms"
            return String(format: format, cap, samples.count, p50, p95, max)
        }

        private func line(_ index: Int) -> Line {
            let text = "[\(index)] Your searing ball of flame does UNSPEAKABLE things "
                + "to an Eldar farmer! [2429]"
            let runs = [
                StyledRun(
                    utf16Range: 0..<min(text.utf16.count, 40),
                    style: StyleAttributes(
                        foreground: .named(index.isMultiple(of: 2) ? .red : .yellow),
                        bold: index.isMultiple(of: 3)
                    )
                )
            ]
            return Line(id: LineID(0), text: text, runs: runs)
        }
    }

    private var soakBenchEnabled: Bool {
        ProcessInfo.processInfo.environment["PROTELES_BENCH"] != nil
    }

    /// Thread-safe flush-duration collector (the spike's pattern).
    private final class FlushCollector: @unchecked Sendable {
        private var times: [Double] = []
        private let lock = NSLock()

        func record(_ duration: Duration) {
            let ms = Double(duration.components.attoseconds) / 1e15
                + Double(duration.components.seconds) * 1000
            lock.withLock { times.append(ms) }
        }

        func snapshot() -> [Double] {
            lock.withLock { times }
        }
    }
#endif

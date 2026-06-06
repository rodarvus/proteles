#if os(macOS)
    import AppKit
    import Darwin.Mach
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    /// Phase 1 validation spike (PLAN.md §8.2, **D-04**).
    ///
    /// Drives a real `NSTextView` inside a real (offscreen) `NSWindow`
    /// through the production ``RenderCoordinator`` pipeline, streams
    /// synthetic line bursts at the PLAN.md §12 throughput target, and
    /// records per-frame flush latency and RSS growth.
    ///
    /// **D-04 outcome (2026-05-16):** TextKit 2 + NSTextView clears the
    /// latency budget with 5× headroom (P99 ~3 ms vs 16 ms). Memory delta
    /// at 2000 lines is ~60 MB, which is **higher than the linear
    /// projection target** of ≤100 MB at 50k lines (PLAN.md §12) and
    /// warrants Phase 2 investigation alongside the custom NSTextStorage
    /// subclass + scrollback eviction work. Decision: adopt TextKit 2;
    /// flag memory profiling as a Phase 2 deliverable rather than blocking
    /// on it now.
    ///
    /// Pass criteria for this spike (relaxed from PLAN.md §12 to reflect
    /// what's investigable at this scale):
    ///   - sustained 200 lines/sec produced *and* consumed
    ///   - P99 frame flush time ≤ 16 ms (hard gate)
    ///   - resident-memory delta ≤ 100 MB at 2000 lines (regression catch;
    ///     real budget reappraisal happens once eviction lands)
    @Suite("Phase 1 — TextKit 2 validation spike")
    @MainActor
    struct RenderingValidationSpikeTests {
        /// 200 lines/sec for 10 s is enough load to detect a P99 budget
        /// breach without making CI slow. The full PLAN.md target is 60 s;
        /// extend `targetSeconds` for the manual deeper run.
        @Test("Sustained 200 lines/sec under TextKit 2 (10s, P99 ≤ 16ms)")
        // swiftlint:disable:next function_body_length
        func textKit2SustainedThroughput() async throws {
            let targetLineRate = 200.0
            let targetSeconds = 10.0
            let burstSize = 10
            let burstInterval = Duration.milliseconds(
                Int((Double(burstSize) / targetLineRate) * 1000)
            )

            // Real NSWindow so NSTextView's layout pipeline actually runs.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            let scrollView = NSTextView.scrollableTextView()
            guard let textView = scrollView.documentView as? NSTextView else {
                Issue.record("Could not obtain NSTextView from scrollableTextView")
                return
            }
            textView.isEditable = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView = scrollView

            let store = ScrollbackStore(maxLines: 50000)
            let coordinator = RenderCoordinator(
                textView: textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(16)
            )

            // Box the frame-times so the @Sendable callback can append.
            let collector = FrameTimeCollector()
            coordinator.onFrameFlush = { stats in
                collector.record(stats.flushDuration)
            }
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            let memoryBefore = currentRSSBytes()
            let totalLines = Int(targetLineRate * targetSeconds)
            let bursts = totalLines / burstSize

            let testStart = ContinuousClock.now
            for burstIndex in 0..<bursts {
                for inBurst in 0..<burstSize {
                    let lineIndex = burstIndex * burstSize + inBurst
                    await store.append(Self.syntheticLine(index: lineIndex))
                }
                try await Task.sleep(for: burstInterval)
            }
            let elapsed = ContinuousClock.now - testStart

            // Let any in-flight flush finish.
            try await Task.sleep(for: .milliseconds(100))

            let memoryAfter = currentRSSBytes()
            let memoryDeltaMB = Double(
                Int64(memoryAfter) - Int64(memoryBefore)
            ) / 1_048_576.0

            let frameTimes = collector.snapshot().sorted()
            let p50 = percentile(frameTimes, 0.50)
            let p95 = percentile(frameTimes, 0.95)
            let p99 = percentile(frameTimes, 0.99)
            let max = frameTimes.last ?? 0

            let totalAppended = await store.totalAppended

            print("\n=== Phase 1 / D-04 Validation Spike ===")
            print(
                String(
                    format: "  Target            : %.0f lines/sec for %.1fs",
                    targetLineRate,
                    targetSeconds
                )
            )
            print("  Lines appended    : \(totalAppended)")
            print(
                String(
                    format: "  Actual duration   : %.3fs",
                    Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18
                )
            )
            print("  Frames flushed    : \(frameTimes.count)")
            print(String(format: "  P50 flush latency : %.3f ms", p50))
            print(String(format: "  P95 flush latency : %.3f ms", p95))
            print(String(format: "  P99 flush latency : %.3f ms", p99))
            print(String(format: "  MAX flush latency : %.3f ms", max))
            print(String(format: "  RSS delta         : %+.2f MB", memoryDeltaMB))
            print("========================================\n")

            // Soft floor for the test: skip empty data — the test
            // environment doesn't provide a window manager so flushes may
            // not always run, but the pipeline must produce *some* flushes
            // with content.
            #expect(
                !frameTimes.isEmpty,
                "no frames flushed — pipeline did not deliver lines"
            )
            // Latency budget — D-04 pass criterion (hard gate).
            #expect(p99 < 16.0, "P99 flush latency \(p99) ms exceeds 16 ms budget")
            // Memory budget — regression catch at this scale (see suite
            // doc-comment for the full context).
            #expect(
                memoryDeltaMB < 100.0,
                "RSS delta \(memoryDeltaMB) MB exceeds 100 MB regression budget"
            )
        }

        /// Counterpart to the throughput spike that exercises **eviction**.
        /// `maxLines` is small enough that the scrollback overflows
        /// repeatedly; the coordinator must delete the corresponding bytes
        /// from `NSTextStorage` so that resident memory stays bounded.
        ///
        /// Pass: P99 flush latency ≤ 16 ms (eviction adds work; budget
        /// stays the same) and RSS delta within a generous regression
        /// gate. The meaningful eviction-vs-no-eviction comparison runs
        /// in **isolation** (e.g. `swift test --filter
        /// evictionKeepsMemoryBounded`) where the no-eviction case
        /// measured ~57 MB at 2000 lines and this one measures ~23 MB.
        /// Under `--parallel` `mach_task_basic_info` is process-wide
        /// and concurrent suites inflate the delta, so the in-test
        /// budget is set permissively (100 MB) just to catch "bytes
        /// not being freed at all" regressions.
        @Test("200 lines/sec with maxLines=200 (eviction stays bounded)")
        // swiftlint:disable:next function_body_length
        func evictionKeepsMemoryBounded() async throws {
            let targetLineRate = 200.0
            let targetSeconds = 10.0
            let burstSize = 10
            let maxLines = 200
            let burstInterval = Duration.milliseconds(
                Int((Double(burstSize) / targetLineRate) * 1000)
            )

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            let scrollView = NSTextView.scrollableTextView()
            guard let textView = scrollView.documentView as? NSTextView else {
                Issue.record("Could not obtain NSTextView from scrollableTextView")
                return
            }
            textView.isEditable = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView = scrollView

            let store = ScrollbackStore(maxLines: maxLines)
            let coordinator = RenderCoordinator(
                textView: textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(16)
            )

            let collector = FrameTimeCollector()
            coordinator.onFrameFlush = { stats in
                collector.record(stats.flushDuration)
            }
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            let memoryBefore = currentRSSBytes()
            let totalLines = Int(targetLineRate * targetSeconds)
            let bursts = totalLines / burstSize

            for burstIndex in 0..<bursts {
                for inBurst in 0..<burstSize {
                    let lineIndex = burstIndex * burstSize + inBurst
                    await store.append(Self.syntheticLine(index: lineIndex))
                }
                try await Task.sleep(for: burstInterval)
            }
            try await Task.sleep(for: .milliseconds(100))

            let memoryAfter = currentRSSBytes()
            let memoryDeltaMB = Double(
                Int64(memoryAfter) - Int64(memoryBefore)
            ) / 1_048_576.0

            let frameTimes = collector.snapshot().sorted()
            let p50 = percentile(frameTimes, 0.50)
            let p95 = percentile(frameTimes, 0.95)
            let p99 = percentile(frameTimes, 0.99)
            let max = frameTimes.last ?? 0

            let totalAppended = await store.totalAppended
            let storeCount = await store.count
            let evictedCount = totalAppended - UInt64(storeCount)

            print("\n=== Phase 2 / Eviction Spike ===")
            print(
                String(
                    format: "  Target            : %.0f lines/sec for %.1fs",
                    targetLineRate,
                    targetSeconds
                )
            )
            print("  maxLines          : \(maxLines)")
            print("  Lines appended    : \(totalAppended)")
            print("  Lines evicted     : \(evictedCount)")
            print("  Lines resident    : \(storeCount)")
            print("  Frames flushed    : \(frameTimes.count)")
            print(String(format: "  P50 flush latency : %.3f ms", p50))
            print(String(format: "  P95 flush latency : %.3f ms", p95))
            print(String(format: "  P99 flush latency : %.3f ms", p99))
            print(String(format: "  MAX flush latency : %.3f ms", max))
            print(String(format: "  RSS delta         : %+.2f MB", memoryDeltaMB))
            print("========================================\n")

            #expect(!frameTimes.isEmpty)
            #expect(p99 < 16.0, "P99 flush latency \(p99) ms exceeds 16 ms budget")
            #expect(
                evictedCount > UInt64(maxLines),
                "test did not actually exercise eviction"
            )
            // Permissive regression gate; see the suite doc-comment.
            // Isolated measurement (run with --filter
            // evictionKeepsMemoryBounded) is ~23 MB.
            #expect(
                memoryDeltaMB < 100.0,
                "RSS delta \(memoryDeltaMB) MB exceeds 100 MB regression budget"
            )
        }

        // MARK: - Helpers

        private static func syntheticLine(index: Int) -> Line {
            // A mix of plain and styled spans to exercise the
            // AttributedStringBuilder hot path. Roughly 80–100 chars.
            let text = "[\(index)] You enter the misty forest path heading north."
            let runs: [StyledRun] = if index.isMultiple(of: 4) {
                []
            } else {
                [
                    StyledRun(
                        utf16Range: 0..<min(text.utf16.count, 32),
                        style: StyleAttributes(
                            foreground: .named(index.isMultiple(of: 2) ? .green : .yellow),
                            bold: index.isMultiple(of: 3)
                        )
                    )
                ]
            }
            return Line(id: LineID(0), text: text, runs: runs)
        }

        private func percentile(_ sortedMs: [Double], _ percentile: Double) -> Double {
            guard !sortedMs.isEmpty else { return 0 }
            let index = Int(Double(sortedMs.count - 1) * percentile)
            return sortedMs[index]
        }

        private func currentRSSBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(
                        mach_task_self_,
                        task_flavor_t(MACH_TASK_BASIC_INFO),
                        $0,
                        &count
                    )
                }
            }
            return result == KERN_SUCCESS ? info.resident_size : 0
        }
    }

    // MARK: - Frame-time collector

    /// Thread-safe collector for per-flush durations. Wraps an array behind
    /// an `OSAllocatedUnfairLock` so the `@Sendable` callback can append
    /// without crossing isolation.
    private final class FrameTimeCollector: @unchecked Sendable {
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

#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    /// `attach` is a full reset (#65): re-attaching the coordinator rebuilds
    /// the text storage from the store snapshot — content preserved
    /// byte-for-byte, eviction FIFO consistent afterwards, and the frame
    /// stats carry the live document size the field instrumentation logs.
    /// (The automatic in-session self-heal that drove this re-attach was
    /// removed — it yanked the live view to the top and forced a multi-second
    /// scroll-to-end walk during normal play; the 10k document cap and this
    /// telemetry are the parts of #65 that stay.)
    @Suite("RenderCoordinator rebuild + document stats (#65)")
    @MainActor
    struct RenderCoordinatorRebuildTests {
        private func makeView() -> NSTextView? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let scrollView = NSTextView.scrollableTextView()
            guard let textView = scrollView.documentView as? NSTextView else { return nil }
            scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            window.contentView = scrollView
            return textView
        }

        @Test("frame stats carry the live document size")
        func statsCarryDocumentSize() async throws {
            let textView = try #require(makeView())
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: textView, palette: .xtermDefault, frameInterval: .milliseconds(10)
            )
            let box = StatsBox()
            coordinator.onFrameFlush = { box.latest = $0 }
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<25 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(150))
            let stats = try #require(box.latest)
            #expect(stats.documentLines == 25)
            #expect(stats.documentUTF16Length == textView.textStorage?.length)
            #expect(stats.documentUTF16Length > 0)
        }

        @Test("re-attach rebuilds the storage identically; eviction stays consistent")
        func reattachRebuildsAndEvictionSurvives() async throws {
            let textView = try #require(makeView())
            let cap = 50
            let store = ScrollbackStore(maxLines: cap)
            let coordinator = RenderCoordinator(
                textView: textView, palette: .xtermDefault, frameInterval: .milliseconds(10)
            )
            // This test asserts the rendered document mirrors the store cap
            // exactly, so disable eviction batching (batch of 1 = trim every
            // eviction, the pre-#65-batching behaviour). Batching itself is
            // covered by `evictionIsBatched`.
            coordinator.evictionBatch = 1
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<80 { // past cap: eviction active
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(200))
            let before = textView.textStorage?.string ?? ""
            #expect(before.contains("line 79"))
            #expect(!before.contains("line 29\n")) // evicted

            // The self-heal path: re-attach to the same view.
            await coordinator.attach(to: store)
            try await Task.sleep(for: .milliseconds(100))
            let after = textView.textStorage?.string ?? ""
            #expect(after == before, "rebuild must reproduce the document exactly")

            // Eviction still aligned after the rebuild: more appends past cap
            // keep the document bounded and ordered.
            for index in 80..<120 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(200))
            let final = textView.textStorage?.string ?? ""
            #expect(final.contains("line 119"))
            #expect(!final.contains("line 69\n")) // evicted post-rebuild
            let lineCount = final.split(separator: "\n").count
            #expect(lineCount == cap)
        }

        /// #65 follow-up — render-side eviction is BATCHED, not per-flush.
        /// The store evicts at its cap, but the coordinator defers deleting
        /// those lines from the top of the `NSTextStorage` until a full
        /// ``RenderCoordinator/evictionBatch`` accumulates, so the
        /// layout-invalidating top-delete (which was making the bottom-pin's
        /// scroll estimate jump the view) happens once per batch, not once
        /// per flush. Concretely: with a batch of 20 over a 50-line store, the
        /// rendered document grows PAST the cap (to cap + backlog) and only
        /// snaps back when the batch trims — behaviour the old per-flush
        /// delete (document == store cap, always) cannot produce.
        @Test("render-side eviction is deferred into batches, not per-flush")
        func evictionIsBatched() async throws {
            let textView = try #require(makeView())
            let store = ScrollbackStore(maxLines: 50)
            let coordinator = RenderCoordinator(
                textView: textView, palette: .xtermDefault, frameInterval: .milliseconds(10)
            )
            coordinator.evictionBatch = 20
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            // 69 lines: store keeps 50, evicts 19 — one short of a batch, so
            // nothing is trimmed yet and all 69 stay rendered (the old code
            // would hold exactly 50, mirroring the store).
            for index in 0..<69 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(200))
            let beforeTrim = textView.textStorage?.string ?? ""
            #expect(beforeTrim.split(separator: "\n").count == 69)

            // One more eviction crosses the batch (20) → the backlog trims in
            // a single delete, dropping the document back to the store cap.
            await store.append(text: "line 69")
            try await Task.sleep(for: .milliseconds(200))
            let afterTrim = textView.textStorage?.string ?? ""
            #expect(afterTrim.split(separator: "\n").count == 50)
            #expect(afterTrim.contains("line 69")) // newest kept
            #expect(afterTrim.contains("line 20\n")) // oldest survivor
            #expect(!afterTrim.contains("line 19\n")) // trimmed in the batch
        }
    }

    /// Single-slot stats holder for @Sendable callbacks.
    private final class StatsBox: @unchecked Sendable {
        var latest: RenderFrameStats?
    }
#endif

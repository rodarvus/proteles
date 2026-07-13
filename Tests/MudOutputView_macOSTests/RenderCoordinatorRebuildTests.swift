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
    @Suite("RenderCoordinator rebuild + document stats (#65)", .serialized)
    @MainActor
    struct RenderCoordinatorRebuildTests {
        private func makeView() -> NSTextView? {
            makeScrollView()?.documentView as? NSTextView
        }

        private func makeScrollView() -> NSScrollView? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let scrollView = NSTextView.scrollableTextView()
            scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            window.contentView = scrollView
            return scrollView
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

        @Test("main storage represents logical lines without an extra terminal paragraph")
        func mainStorageHasNoExtraTerminalParagraph() async throws {
            let textView = try #require(makeView())
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            await store.append(text: "first")
            await store.append(text: "")
            await store.append(text: "third")
            try await Task.sleep(for: .milliseconds(100))
            #expect(textView.string == "first\n\nthird")

            await store.removeLast(1)
            try await Task.sleep(for: .milliseconds(100))
            #expect(textView.string == "first\n")

            await store.append(text: "replacement")
            try await Task.sleep(for: .milliseconds(100))
            #expect(textView.string == "first\n\nreplacement")
        }

        @Test("health snapshots report sanitized main output geometry")
        func healthSnapshotsReportMainOutputGeometry() async throws {
            let viewport = makeOutputViewport()
            let textView = viewport.textView
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: textView, palette: .xtermDefault, frameInterval: .milliseconds(10)
            )
            let box = HealthBox()
            coordinator.onHealthSnapshot = { box.latest = $0 }
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            await store.append(text: "first room")
            try await Task.sleep(for: .milliseconds(150))
            let snapshot = try #require(box.latest)

            #expect(snapshot.surface == "main-output")
            #expect(snapshot.renderedLines == 1)
            #expect(snapshot.storageUTF16Length == textView.textStorage?.length)
            #expect(snapshot.usesTextLayoutManager)
            #expect(snapshot.textViewBoundsWidth > 0)
            #expect(snapshot.visibleWidth > 0)
            #expect(snapshot.transcriptNote(context: "unit").contains("text-health: main-output unit"))
            #expect(snapshot.transcriptNote(context: "unit").contains("source "))
            #expect(!snapshot.transcriptNote(context: "unit").contains("first room"))
        }

        @Test("transient layout distance cannot disengage explicit tail following")
        func layoutLagDoesNotDisengageTailFollowing() async throws {
            let viewport = makeOutputViewport(height: 120)
            let store = ScrollbackStore(maxLines: 500)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(250))

            let maximumY = max(
                0,
                (viewport.scrollView.documentView?.frame.height ?? 0)
                    - viewport.scrollView.contentView.bounds.height
            )
            viewport.scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY - 40))
            viewport.scrollView.reflectScrolledClipView(viewport.scrollView.contentView)
            viewport.scrollView.setInitialScrollMode(.followingTail)
            #expect(!viewport.scrollView.isScrolledToBottom())

            await store.append(text: "line 100")
            try await Task.sleep(for: .milliseconds(200))

            #expect(coordinator.currentScrollMode == .followingTail)
            #expect(viewport.scrollView.isScrolledToBottom())
            #expect(distanceFromBottom(in: viewport) <= 1)
            #expect(TextViewportProbe.viewportEndsAtStorageEnd(in: viewport.textView) == true)
        }

        @Test("review anchor survives a batched prefix trim")
        func reviewAnchorSurvivesBatchedPrefixTrim() async throws {
            let viewport = makeOutputViewport(height: 120)
            let store = ScrollbackStore(maxLines: 50)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            coordinator.evictionBatch = 20
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<69 {
                await store.append(text: "line \(index) content")
            }
            try await Task.sleep(for: .milliseconds(300))

            let range = (viewport.textView.string as NSString).range(of: "line 30 content")
            viewport.textView.scrollRangeToVisible(range)
            viewport.scrollView.noteUserScroll(reason: "unit-review")
            let before = try #require(coordinator.currentViewportAnchor())
            #expect(coordinator.currentScrollMode == .reviewing)

            await store.append(text: "line 69 content")
            try await Task.sleep(for: .milliseconds(300))
            let after = try #require(coordinator.currentViewportAnchor())

            #expect(after.lineID == before.lineID)
            #expect(after.utf16OffsetInLine == before.utf16OffsetInLine)
            #expect(coordinator.currentScrollMode == .reviewing)
        }
    }

    extension RenderCoordinatorRebuildTests {
        @Test("repeated prefix trims reconcile the TextKit viewport to the tail")
        func repeatedPrefixTrimsReconcileViewportToTail() async throws {
            let viewport = makeOutputViewport(height: 400)
            let store = ScrollbackStore(maxLines: 5000)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            coordinator.evictionBatch = 1000
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            try await appendGeometryLines(0..<5000, to: store)
            try await Task.sleep(for: .milliseconds(500))
            #expect(distanceFromBottom(in: viewport) <= 1)
            #expect(TextViewportProbe.viewportEndsAtStorageEnd(in: viewport.textView) == true)
            for cycle in 0..<4 {
                let start = 5000 + cycle * 1000
                try await appendGeometryLines(start..<(start + 1000), to: store)
                try await Task.sleep(for: .milliseconds(250))
                #expect(viewport.textView.string.split(separator: "\n").count == 5000)
                #expect(distanceFromBottom(in: viewport) <= 1)
                #expect(TextViewportProbe.viewportEndsAtStorageEnd(in: viewport.textView) == true)
            }
        }

        @Test("queued tail reconciliation cannot override review intent")
        func queuedTailReconciliationCannotOverrideReviewIntent() async throws {
            let viewport = makeOutputViewport(height: 120)
            let store = ScrollbackStore(maxLines: 500)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index) content")
            }
            try await Task.sleep(for: .milliseconds(250))

            coordinator.requestTailReconciliation(in: viewport.textView, source: "unit")
            let range = (viewport.textView.string as NSString).range(of: "line 20 content")
            viewport.textView.scrollRangeToVisible(range)
            viewport.scrollView.beginReviewing(reason: "unit-review")
            let reviewOrigin = viewport.scrollView.contentView.bounds.origin.y
            try await Task.sleep(for: .milliseconds(100))

            #expect(coordinator.currentScrollMode == .reviewing)
            #expect(abs(viewport.scrollView.contentView.bounds.origin.y - reviewOrigin) < 1)
        }

        @Test("live limit reduction trims immediately and reports its outcome")
        func liveLimitReductionTrimsImmediately() async throws {
            let viewport = makeOutputViewport(height: 120)
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            coordinator.evictionBatch = 1000
            let health = HealthBox()
            coordinator.onHealthSnapshot = { health.latest = $0 }
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(250))
            await store.setLimit(.limited(40))
            try await Task.sleep(for: .milliseconds(250))

            let rendered = viewport.textView.string
            #expect(rendered.split(separator: "\n").count == 40)
            #expect(rendered.contains("line 60\n"))
            #expect(!rendered.contains("line 59\n"))
            #expect(health.latest?.extra.contains("limit limited-40") == true)
            #expect(health.latest?.extra.contains("evicted-60-trimmed-60") == true)
        }

        @Test("a coalesced later increase cannot suppress a required trim")
        func coalescedLimitIncreaseStillTrims() async throws {
            let textView = try #require(makeView())
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(20)
            )
            coordinator.evictionBatch = 1000
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(250))
            await store.setLimit(.limited(40))
            await store.setLimit(.unlimited)
            try await Task.sleep(for: .milliseconds(250))

            #expect(textView.string.split(separator: "\n").count == 40)
            #expect(await store.limit == .unlimited)
        }

        @Test("switching to unlimited flushes an existing deferred eviction backlog")
        func unlimitedFlushesExistingEvictionBacklog() async throws {
            let textView = try #require(makeView())
            let store = ScrollbackStore(maxLines: 50)
            let coordinator = RenderCoordinator(
                textView: textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            coordinator.evictionBatch = 20
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<69 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(250))
            #expect(textView.string.split(separator: "\n").count == 69)

            await store.setLimit(.unlimited)
            try await Task.sleep(for: .milliseconds(250))

            #expect(textView.string.split(separator: "\n").count == 50)
            #expect(textView.string.contains("line 19\n"))
            #expect(!textView.string.contains("line 18\n"))
        }

        @Test("live limit reduction preserves a surviving review anchor")
        func liveLimitReductionPreservesReviewAnchor() async throws {
            let viewport = makeOutputViewport(height: 120)
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index) content")
            }
            try await Task.sleep(for: .milliseconds(250))
            let range = (viewport.textView.string as NSString).range(of: "line 70 content")
            viewport.textView.scrollRangeToVisible(range)
            viewport.scrollView.noteUserScroll(reason: "unit-review")
            let before = try #require(coordinator.currentViewportAnchor())

            await store.setLimit(.limited(50))
            try await Task.sleep(for: .milliseconds(250))
            let after = try #require(coordinator.currentViewportAnchor())

            #expect(after.lineID == before.lineID)
            #expect(after.utf16OffsetInLine == before.utf16OffsetInLine)
            #expect(coordinator.currentScrollMode == .reviewing)
        }

        @Test("live limit reduction clamps an evicted review anchor")
        func liveLimitReductionClampsEvictedReviewAnchor() async throws {
            let viewport = makeOutputViewport(height: 120)
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                palette: .xtermDefault,
                frameInterval: .milliseconds(10)
            )
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index) content")
            }
            try await Task.sleep(for: .milliseconds(250))
            let range = (viewport.textView.string as NSString).range(of: "line 20 content")
            viewport.textView.scrollRangeToVisible(range)
            viewport.scrollView.noteUserScroll(reason: "unit-review")

            await store.setLimit(.limited(50))
            try await Task.sleep(for: .milliseconds(250))
            let after = try #require(coordinator.currentViewportAnchor())

            #expect(after.lineID == LineID(50))
            #expect(coordinator.currentScrollMode == .reviewing)
        }

        @Test("selecting historical output enters review mode")
        func selectingHistoricalOutputEntersReviewMode() async {
            let viewport = makeOutputViewport(height: 120)
            viewport.textView.string = (0..<100)
                .map { "line \($0) content" }
                .joined(separator: "\n")
            viewport.scrollView.followTailAndScrollToBottom(reason: "unit-tail")

            let range = (viewport.textView.string as NSString).range(of: "line 20 content")
            viewport.textView.scrollRangeToVisible(range)
            viewport.textView.setSelectedRange(range)
            viewport.textView.textViewDidChangeSelection(
                Notification(name: NSTextView.didChangeSelectionNotification)
            )
            await Task.yield()

            #expect(viewport.scrollView.scrollMode == .reviewing)
            #expect(viewport.scrollView.scrollModeReason == "selection")
        }

        @Test("initial top scroll position leaves static snapshots at the beginning")
        func initialTopScrollPosition() async throws {
            let scrollView = try #require(makeScrollView())
            let textView = try #require(scrollView.documentView as? NSTextView)
            let store = ScrollbackStore(maxLines: 300)
            for index in 0..<180 {
                await store.append(text: "line \(index)")
            }
            let coordinator = RenderCoordinator(
                textView: textView,
                palette: .xtermDefault,
                initialScrollPosition: .top,
                frameInterval: .milliseconds(10)
            )

            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            #expect(scrollView.contentView.bounds.origin.y <= 1)
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

        private func makeOutputViewport(height: CGFloat = 400) -> TestOutputViewport {
            TestOutputViewport(height: height)
        }

        private func distanceFromBottom(in viewport: TestOutputViewport) -> CGFloat {
            let documentHeight = viewport.scrollView.documentView?.frame.height ?? 0
            return documentHeight - viewport.scrollView.contentView.documentVisibleRect.maxY
        }

        private func makeGeometryLine(_ index: Int) -> Line {
            let widths = [12, 24, 48, 72, 96, 140, 220, 36, 64, 88]
            let width = widths[index % widths.count]
            return Line(
                id: LineID(0),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                text: String(repeating: "a", count: width)
            )
        }

        private func appendGeometryLines(
            _ range: Range<Int>,
            to store: ScrollbackStore
        ) async throws {
            for start in stride(from: range.lowerBound, to: range.upperBound, by: 25) {
                let end = min(start + 25, range.upperBound)
                await store.appendBatch((start..<end).map(makeGeometryLine))
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// Single-slot stats holder for @Sendable callbacks.
    private final class StatsBox: @unchecked Sendable {
        var latest: RenderFrameStats?
    }

    private final class HealthBox: @unchecked Sendable {
        var latest: TextViewHealthSnapshot?
    }

    @MainActor
    private final class TestOutputViewport {
        let window: NSWindow
        let scrollView: BottomPinnedOutputScrollView
        let textView: MudTextView

        init(height: CGFloat) {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            scrollView = BottomPinnedOutputScrollView(
                frame: NSRect(x: 0, y: 0, width: 600, height: height)
            )
            textView = MudTextView()
            textView.delegate = textView
            textView.minSize = .zero
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
            scrollView.documentView = textView
            window.contentView = scrollView
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
#endif

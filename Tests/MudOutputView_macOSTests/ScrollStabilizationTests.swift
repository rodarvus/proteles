#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    @Suite("Output scroll stabilization", .serialized)
    @MainActor
    struct ScrollStabilizationTests {
        @Test("ordinary appends preserve a review viewport at the tail")
        func ordinaryAppendPreservesReviewViewport() async throws {
            let viewport = TestViewport(height: 160)
            let store = ScrollbackStore(maxLines: 500)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                frameInterval: .milliseconds(10)
            )
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index) content")
            }
            try await Task.sleep(for: .milliseconds(250))
            viewport.scrollView.beginReviewing(reason: "selection")
            let originBeforeAppend = viewport.scrollView.contentView.bounds.origin.y

            await store.append(text: "line 100 content")
            try await Task.sleep(for: .milliseconds(100))

            #expect(coordinator.currentScrollMode == .reviewing)
            #expect(abs(viewport.scrollView.contentView.bounds.origin.y - originBeforeAppend) < 1)
            #expect(viewport.distanceFromBottom > 1)
        }

        @Test("deferred anchor refinement yields to a newer gesture")
        func deferredAnchorRefinementYieldsToGesture() async throws {
            let viewport = TestViewport(height: 160)
            let lines = (0..<100).map { "line \($0) content\n" }
            viewport.textView.string = lines.joined()
            viewport.window.contentView?.layoutSubtreeIfNeeded()
            let spans = lines.enumerated().map { index, line in
                RenderedLineSpan(id: LineID(UInt64(index)), utf16Length: line.utf16.count)
            }
            let range = (viewport.textView.string as NSString).range(of: "line 50 content")
            viewport.textView.scrollRangeToVisible(range)
            viewport.scrollView.beginReviewing(reason: "unit-review")
            let anchor = try #require(TextViewportProbe.captureAnchor(
                in: viewport.textView,
                renderedLines: spans
            ))

            _ = TextViewportProbe.restoreAnchor(
                anchor,
                in: viewport.textView,
                renderedLines: spans
            )
            let userRange = (viewport.textView.string as NSString).range(of: "line 5 content")
            viewport.textView.scrollRangeToVisible(userRange)
            viewport.scrollView.noteUserScroll(reason: "unit-review")
            viewport.scrollView.reflectScrolledClipView(viewport.scrollView.contentView)
            let userOrigin = viewport.scrollView.contentView.bounds.origin.y
            try await Task.sleep(for: .milliseconds(50))

            #expect(abs(viewport.scrollView.contentView.bounds.origin.y - userOrigin) < 1)
        }

        @Test("live-tail refresh settles at the exact document bottom")
        func liveTailRefreshSettlesAtBottom() async throws {
            let viewport = TestViewport(height: 160)
            let tail = TestTailViewport(height: 111.5)
            let store = ScrollbackStore(maxLines: 500)
            let coordinator = RenderCoordinator(
                textView: viewport.textView,
                frameInterval: .milliseconds(10)
            )
            var healthSnapshots: [String: TextViewHealthSnapshot] = [:]
            coordinator.onHealthSnapshot = { healthSnapshots[$0.surface] = $0 }
            coordinator.attachTail(textView: tail.textView, lineCount: 50)
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<100 {
                await store.append(text: "line \(index) content")
            }
            try await Task.sleep(for: .milliseconds(250))
            #expect(abs(tail.distanceFromBottom) < 0.25)

            for index in 100..<125 {
                await store.append(text: "line \(index) content")
            }
            try await Task.sleep(for: .milliseconds(150))
            #expect(abs(tail.distanceFromBottom) < 0.25)
            #expect(!tail.textView.string.hasSuffix("\n"))
            let tailHealth = try #require(healthSnapshots["main-output-tail"])
            #expect(tailHealth.isPinnedToBottom)
            #expect(abs(tailHealth.distanceFromBottom) < 0.25)
        }

        @Test("live-tail pin is exact before the next layout turn")
        func liveTailPinIsImmediatelyExact() {
            let tail = TestTailViewport(height: 111.5)
            tail.textView.string = (0..<50)
                .map { "line \($0) content that wraps across the tail viewport\n" }
                .joined()

            tail.scrollView.scrollToDocumentBottom()
            tail.window.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(tail.distanceFromBottom) < 0.25)

            tail.scrollView.setFrameSize(NSSize(width: 600, height: 173.5))
            tail.scrollView.scrollToDocumentBottom()
            tail.window.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(tail.distanceFromBottom) < 0.25)
        }
    }

    @MainActor
    private final class TestViewport {
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

        var distanceFromBottom: CGFloat {
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            return documentHeight - scrollView.contentView.documentVisibleRect.maxY
        }
    }

    @MainActor
    private final class TestTailViewport {
        let window: NSWindow
        let scrollView: PassthroughScrollView
        let textView: MudTextView

        init(height: CGFloat) {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            scrollView = PassthroughScrollView(
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

        var distanceFromBottom: CGFloat {
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            return documentHeight - scrollView.contentView.documentVisibleRect.maxY
        }
    }
#endif

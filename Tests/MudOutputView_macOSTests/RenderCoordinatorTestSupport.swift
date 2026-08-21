#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    // Shared fixtures for `RenderCoordinatorRebuildTests`, split out to keep
    // that suite inside the 600-line file budget. `TestOutputViewport` is the
    // load-bearing piece: it builds a window/scroll-view/text-view stack with
    // EXPLICIT geometry, which is what makes the suite behave the same on a
    // developer machine and on CI (#26).

    /// Single-slot stats holder for @Sendable callbacks.
    final class StatsBox: @unchecked Sendable {
        var latest: RenderFrameStats?
    }

    final class HealthBox: @unchecked Sendable {
        var latest: TextViewHealthSnapshot?
    }

    @MainActor
    final class TestOutputViewport {
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

            // Size the document view EXPLICITLY rather than trusting
            // NSScrollView to size a zero-frame document view for us (#26).
            // That implicit path is environment-sensitive: on a developer
            // machine `scrollView.documentView = textView` immediately widens
            // the view to the clip bounds, but on CI it did not, leaving a
            // zero-width text view. Every line then wrapped to a single
            // character, which inflated the document to ~80,000pt and broke
            // both the geometry assertions and the scroll-to-tail ones — the
            // four-test failure that kept this job red for six weeks.
            //
            // These tests are about the coordinator's behaviour over a viewport
            // of known size, so the viewport's size should be stated, not
            // inferred.
            let content = scrollView.contentSize
            textView.frame = NSRect(origin: .zero, size: content)
            textView.textContainer?.containerSize = NSSize(
                width: content.width - textView.textContainerInset.width * 2,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.layoutSubtreeIfNeeded()
        }

        /// Geometry, for failure messages — a bare `width → 0.0` says nothing
        /// about which part of the fixture gave up.
        var geometrySummary: String {
            "textView.bounds=\(textView.bounds) clip=\(scrollView.contentView.bounds) "
                + "container=\(textView.textContainer?.containerSize.width ?? -1) "
                + "screens=\(NSScreen.screens.count)"
        }
    }
#endif

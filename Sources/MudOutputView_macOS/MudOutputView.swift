#if os(macOS)
    import AppKit
    import MudCore
    import SwiftUI

    /// AppKit-backed text view that hosts the streaming MUD output.
    ///
    /// Wraps an `NSTextView` inside an `NSScrollView` and binds it to a
    /// ``ScrollbackStore`` via ``RenderCoordinator``. The coordinator
    /// coalesces per-line appends into one transaction per frame (PLAN.md
    /// §6.3 / **D-01**).
    public struct MudOutputView: NSViewRepresentable {
        private let store: ScrollbackStore
        private let palette: ColorPalette
        private let fontSize: CGFloat
        private let onCommand: ((String) -> Void)?

        public init(
            store: ScrollbackStore,
            palette: ColorPalette = .xtermDefault,
            fontSize: CGFloat = 13,
            onCommand: ((String) -> Void)? = nil
        ) {
            self.store = store
            self.palette = palette
            self.fontSize = fontSize
            self.onCommand = onCommand
        }

        /// Number of lines kept in the live-tail pane (the Mudlet-style split
        /// shown while scrolled back).
        private static let tailLineCount = 10

        public func makeNSView(context: Context) -> NSView {
            // Main history scroll view + our MudTextView subclass (we hand-roll
            // the pair rather than NSTextView.scrollableTextView() so we get the
            // copyWithCodes(_:) action and hyperlink routing).
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            // Overlay scrollers: hidden at rest, fading in only while scrolling
            // (standard macOS behaviour) so they never eat output width.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            let textView = makeTextView()
            scrollView.documentView = textView

            // Live-tail pane: a small bottom mirror of the latest lines, shown
            // only when scrolled up (see SplitOutputContainer). Scroll gestures
            // over it are forwarded to the history view, so you can always
            // scroll back to the bottom (which dismisses the split) even with
            // the cursor over the overlay.
            let tailScrollView = PassthroughScrollView()
            tailScrollView.forwardingTarget = scrollView
            tailScrollView.hasVerticalScroller = false
            tailScrollView.hasHorizontalScroller = false
            tailScrollView.drawsBackground = true
            tailScrollView.backgroundColor = NSColor(palette.defaultBackground)
            tailScrollView.borderType = .noBorder
            let tailTextView = makeTextView()
            tailScrollView.documentView = tailTextView

            let lineHeight = NSLayoutManager().defaultLineHeight(
                for: tailTextView.font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            )
            let tailHeight = ceil(lineHeight * CGFloat(Self.tailLineCount)) + 16 // inset slack

            let container = SplitOutputContainer(
                scrollView: scrollView,
                tailScrollView: tailScrollView,
                tailHeight: tailHeight
            )

            let coordinator = RenderCoordinator(textView: textView, palette: palette)
            coordinator.attachTail(textView: tailTextView, lineCount: Self.tailLineCount)
            context.coordinator.renderCoordinator = coordinator
            let storeRef = store
            Task { @MainActor in
                await coordinator.attach(to: storeRef)
            }

            return container
        }

        public func updateNSView(_: NSView, context _: Context) {}

        /// Build a configured read-only `MudTextView` (used for both the main
        /// history view and the live-tail mirror).
        private func makeTextView() -> MudTextView {
            let textView = MudTextView()
            textView.onCommand = onCommand
            textView.delegate = textView // self-delegate for hyperlink clicks
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
            configure(textView)
            return textView
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        public final class Coordinator {
            var renderCoordinator: RenderCoordinator?
        }

        // MARK: - Private

        private func configure(_ textView: NSTextView) {
            textView.isEditable = false
            textView.isRichText = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.allowsUndo = false
            textView.backgroundColor = NSColor(palette.defaultBackground)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.font = NSFont.monospacedSystemFont(
                ofSize: fontSize,
                weight: .regular
            )
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
        }
    }
#endif

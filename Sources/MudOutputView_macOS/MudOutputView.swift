#if os(macOS)
    import AppKit
    import MudCore
    import SwiftUI

    /// AppKit-backed text view that hosts the streaming MUD output.
    ///
    /// Wraps an `NSTextView` inside an `NSScrollView` and binds it to a
    /// ``ScrollbackStore`` via ``RenderCoordinator``. The coordinator
    /// coalesces per-line appends into one transaction per frame (ARCHITECTURE.md
    /// §6.3 / **D-01**).
    public struct MudOutputView: NSViewRepresentable {
        private let store: ScrollbackStore
        private let palette: ColorPalette
        private let fontSize: CGFloat
        private let fontName: String
        private let onCommand: ((String) -> Void)?
        /// Whether to show the Mudlet-style live-tail split (a bottom mirror of
        /// the newest lines while scrolled up). Pointless for static content
        /// like a captured help article, so the Help window turns it off.
        private let showsLiveTail: Bool
        /// Where the already-resident snapshot should land when this view first
        /// attaches to its store.
        private let initialScrollPosition: RenderCoordinator.InitialScrollPosition
        /// Per-frame render-cost probe: invoked with each flush's telemetry
        /// (paint cost + worst arrival→paint latency) so a caller can log slow
        /// text-render frames to the session transcript (perf diagnosis — see
        /// ``RenderCoordinator/RenderFrameStats``).
        private let onFrameFlush: ((RenderFrameStats) -> Void)?
        private let onHealthSnapshot: ((TextViewHealthSnapshot) -> Void)?
        /// Opt this instance's history view into ⌘F (the system find bar,
        /// D-104). Exactly one view per window should be findable, so
        /// ``MudOutputFindBar`` can locate it unambiguously — the app turns
        /// this on for the main game output only.
        private let findable: Bool

        public init(
            store: ScrollbackStore,
            palette: ColorPalette = .xtermDefault,
            fontSize: CGFloat = 13,
            fontName: String = "",
            showsLiveTail: Bool = true,
            initialScrollPosition: RenderCoordinator.InitialScrollPosition = .bottom,
            findable: Bool = false,
            onCommand: ((String) -> Void)? = nil,
            onFrameFlush: ((RenderFrameStats) -> Void)? = nil,
            onHealthSnapshot: ((TextViewHealthSnapshot) -> Void)? = nil
        ) {
            self.store = store
            self.palette = palette
            self.fontSize = fontSize
            self.fontName = fontName
            self.showsLiveTail = showsLiveTail
            self.initialScrollPosition = initialScrollPosition
            self.findable = findable
            self.onCommand = onCommand
            self.onFrameFlush = onFrameFlush
            self.onHealthSnapshot = onHealthSnapshot
        }

        /// The base output font: the named family if available, else the system
        /// monospaced font. Bold/italic variants derive from this in the builder.
        private var baseFont: NSFont {
            if !fontName.isEmpty, let named = NSFont(name: fontName, size: fontSize) {
                return named
            }
            return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        /// Number of lines kept in the live-tail pane (the Mudlet-style split
        /// shown while scrolled back).
        private static let tailLineCount = 10

        public func makeNSView(context: Context) -> NSView {
            // Main history scroll view + our MudTextView subclass (we hand-roll
            // the pair rather than NSTextView.scrollableTextView() so we get the
            // copyWithCodes(_:) action and hyperlink routing).
            let scrollView = BottomPinnedOutputScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            // Overlay scrollers: hidden at rest, fading in only while scrolling
            // (standard macOS behaviour) so they never eat output width.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            let textView = makeTextView()
            // The find bar lives on the history view only — never the tail
            // mirror (it holds just the last few lines, so finding there
            // would silently search a fraction of the scrollback).
            textView.usesFindBar = findable
            textView.isIncrementalSearchingEnabled = findable
            scrollView.documentView = textView
            // Accessibility / XCUITest hook (#26 Phase 0): label the live game
            // output. The same component backs the Help reader (showsLiveTail ==
            // false), which keeps the default NSTextView AX so it isn't
            // mislabelled as game output.
            if showsLiveTail {
                textView.identifier = NSUserInterfaceItemIdentifier("proteles.main-output")
                textView.setAccessibilityIdentifier("mud-output")
                textView.setAccessibilityLabel("MUD output")
            }

            // Static content (the Help window): a plain scroll view, no live-tail
            // split — there's nothing "streaming" to mirror.
            if !showsLiveTail {
                let coordinator = makeRenderCoordinator(textView: textView)
                coordinator.onFrameFlush = onFrameFlush
                coordinator.onHealthSnapshot = onHealthSnapshot
                context.coordinator.renderCoordinator = coordinator
                let storeRef = store
                Task { @MainActor in
                    await coordinator.attach(to: storeRef)
                }
                return scrollView
            }

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
            tailTextView.setAccessibilityIdentifier("mud-output-tail")
            tailTextView.setAccessibilityLabel("MUD output, recent lines")

            let lineHeight = NSLayoutManager().defaultLineHeight(for: tailTextView.font ?? baseFont)
            let tailHeight = ceil(lineHeight * CGFloat(Self.tailLineCount)) + 16 // inset slack

            let container = SplitOutputContainer(
                scrollView: scrollView,
                tailScrollView: tailScrollView,
                tailHeight: tailHeight,
                lineHeight: lineHeight
            )

            let coordinator = makeRenderCoordinator(textView: textView)
            coordinator.attachTail(textView: tailTextView, lineCount: Self.tailLineCount)
            coordinator.onFrameFlush = onFrameFlush
            coordinator.onHealthSnapshot = onHealthSnapshot
            configureWheelDiagnostics(on: scrollView, coordinator: coordinator)
            context.coordinator.renderCoordinator = coordinator
            let storeRef = store
            Task { @MainActor in
                await coordinator.attach(to: storeRef)
            }

            return container
        }

        public func updateNSView(_ nsView: NSView, context: Context) {
            context.coordinator.renderCoordinator?.onFrameFlush = onFrameFlush
            context.coordinator.renderCoordinator?.onHealthSnapshot = onHealthSnapshot
            updateWheelDiagnostics(
                in: nsView,
                coordinator: context.coordinator.renderCoordinator
            )
        }

        /// Cancel the render coordinator's frame ticker + store subscription when
        /// SwiftUI tears the view down (e.g. an `.id(...)` change recreating it),
        /// so the per-frame loop never lingers as a zombie eating the main actor.
        public static func dismantleNSView(_: NSView, coordinator: Coordinator) {
            coordinator.renderCoordinator?.detach()
        }

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

        private func makeRenderCoordinator(textView: NSTextView) -> RenderCoordinator {
            RenderCoordinator(
                textView: textView,
                palette: palette,
                initialScrollPosition: initialScrollPosition
            )
        }

        private func configureWheelDiagnostics(
            on scrollView: BottomPinnedOutputScrollView,
            coordinator: RenderCoordinator
        ) {
            guard onHealthSnapshot != nil else {
                scrollView.onWheelDiagnostic = nil
                return
            }
            scrollView.onWheelDiagnostic = { [weak coordinator] reason in
                coordinator?.emitHealth(reason: reason)
            }
        }

        private func updateWheelDiagnostics(
            in view: NSView,
            coordinator: RenderCoordinator?
        ) {
            guard let scrollView = outputScrollView(in: view) else { return }
            guard let coordinator else { return }
            configureWheelDiagnostics(on: scrollView, coordinator: coordinator)
        }

        private func outputScrollView(in view: NSView) -> BottomPinnedOutputScrollView? {
            if let scrollView = view as? BottomPinnedOutputScrollView {
                return scrollView
            }
            return (view as? SplitOutputContainer)?.scrollView
                as? BottomPinnedOutputScrollView
        }

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
            textView.font = baseFont
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
        }
    }
#endif

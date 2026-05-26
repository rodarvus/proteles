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
        private let onCommand: ((String) -> Void)?

        public init(
            store: ScrollbackStore,
            palette: ColorPalette = .xtermDefault,
            onCommand: ((String) -> Void)? = nil
        ) {
            self.store = store
            self.palette = palette
            self.onCommand = onCommand
        }

        public func makeNSView(context: Context) -> NSScrollView {
            // We hand-roll the NSScrollView + MudTextView pair rather
            // than calling NSTextView.scrollableTextView(), because the
            // latter returns a stock NSTextView and we need our
            // ``MudTextView`` subclass for the `copyWithCodes(_:)`
            // action.
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.borderType = .noBorder
            scrollView.translatesAutoresizingMaskIntoConstraints = false

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

            scrollView.documentView = textView

            let coordinator = RenderCoordinator(
                textView: textView,
                palette: palette
            )
            context.coordinator.renderCoordinator = coordinator
            let storeRef = store
            Task { @MainActor in
                await coordinator.attach(to: storeRef)
            }

            return scrollView
        }

        public func updateNSView(_: NSScrollView, context _: Context) {}

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
                ofSize: 13,
                weight: .regular
            )
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
        }
    }
#endif

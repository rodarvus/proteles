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

        public init(
            store: ScrollbackStore,
            palette: ColorPalette = .xtermDefault
        ) {
            self.store = store
            self.palette = palette
        }

        public func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.borderType = .noBorder

            guard let textView = scrollView.documentView as? NSTextView else {
                return scrollView
            }
            configure(textView)

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

#if os(macOS)
    import AppKit
    import MudCore
    import SwiftUI

    /// AppKit-backed text view that hosts the streaming MUD output.
    ///
    /// Phase 0: a read-only, monospaced `NSTextView` inside a scroll view, with
    /// no content. Subsequent phases wire in the scrollback model, a custom
    /// `NSTextStorage` subclass, and render coalescing — see PLAN.md §6.
    public struct MudOutputView: NSViewRepresentable {
        public init() {}

        public func makeNSView(context _: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.borderType = .noBorder

            guard let textView = scrollView.documentView as? NSTextView else {
                return scrollView
            }
            textView.isEditable = false
            textView.isRichText = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.allowsUndo = false
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0

            return scrollView
        }

        public func updateNSView(_: NSScrollView, context _: Context) {
            // Phase 0: no content updates. Phase 1 will pipe Lines in here.
        }
    }
#endif

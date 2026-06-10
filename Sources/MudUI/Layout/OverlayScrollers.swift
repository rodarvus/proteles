import SwiftUI

#if os(macOS)
    import AppKit

    /// Forces the enclosing `NSScrollView` to overlay, auto-hiding scrollers —
    /// the main output's behaviour (`MudOutputView` sets the same two
    /// properties on its hand-rolled scroll view). SwiftUI's `ScrollView`
    /// offers no equivalent: `.scrollIndicators(.automatic)` leaves a
    /// permanent legacy scroller when the system is set to always show
    /// scroll bars — the Channels panel's long-standing ever-present bar.
    ///
    /// Place *inside* the scroll content (e.g. `.background` on the content
    /// stack): the probe view is then a descendant of the backing
    /// `NSScrollView` and finds it by walking superviews.
    private struct OverlayScrollerConfigurator: NSViewRepresentable {
        func makeNSView(context _: Context) -> NSView {
            let probe = NSView()
            DispatchQueue.main.async { configure(from: probe) }
            return probe
        }

        func updateNSView(_ probe: NSView, context _: Context) {
            DispatchQueue.main.async { configure(from: probe) }
        }

        private func configure(from probe: NSView) {
            var view: NSView? = probe
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                    return
                }
                view = current.superview
            }
        }
    }
#endif

extension View {
    /// Overlay, auto-hiding scrollers for the enclosing SwiftUI `ScrollView`
    /// — apply to the scroll *content*. No-op on non-macOS platforms.
    @ViewBuilder
    func overlayScrollers() -> some View {
        #if os(macOS)
            background(OverlayScrollerConfigurator())
        #else
            self
        #endif
    }
}

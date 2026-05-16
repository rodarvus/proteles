#if os(macOS)
    import AppKit
    @testable import MudOutputView_macOS
    import Testing

    @Suite("MudOutputView (macOS) smoke")
    @MainActor
    struct MudOutputViewSmokeTests {
        @Test("View type initializes")
        func viewTypeInitializes() {
            // Phase 0 smoke: the type compiles, exports publicly, and constructs.
            // We deliberately do not exercise `makeNSView(context:)` here because
            // `NSViewRepresentable.Context` has no public initializer, so an
            // out-of-SwiftUI unit test cannot synthesize one without UI host
            // infrastructure. Phase 1 introduces a configuration-protocol seam
            // that we can test directly; until then this guards against the
            // target failing to compile or link.
            _ = MudOutputView()
        }
    }
#endif

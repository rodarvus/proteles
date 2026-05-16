#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    @Suite("MudOutputView (macOS) smoke")
    @MainActor
    struct MudOutputViewSmokeTests {
        @Test("View type initializes against a ScrollbackStore")
        func viewTypeInitializes() {
            // Phase 1 smoke: the type compiles, exports publicly, and accepts
            // a ScrollbackStore. `makeNSView` requires a SwiftUI Context that
            // has no public initializer, so it is exercised by integration
            // tests (see RenderingValidationSpikeTests) rather than here.
            _ = MudOutputView(store: ScrollbackStore())
        }
    }
#endif

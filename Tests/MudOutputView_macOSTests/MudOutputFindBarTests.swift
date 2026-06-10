#if os(macOS)
    import AppKit
    @testable import MudOutputView_macOS
    import Testing

    @MainActor
    @Suite("find-in-scrollback — findable-view lookup (D-104)")
    struct MudOutputFindBarTests {
        @Test("finds the (single) find-bar-enabled text view, however deep")
        func findsFlaggedView() {
            let findable = NSTextView()
            findable.usesFindBar = true
            let inner = NSView()
            inner.addSubview(findable)
            let root = NSView()
            root.addSubview(NSView())
            root.addSubview(inner)
            #expect(MudOutputFindBar.findableTextView(in: root) === findable)
        }

        @Test("ignores text views that didn't opt in (the tail mirror, panels)")
        func ignoresUnflaggedViews() {
            let plain = NSTextView() // usesFindBar defaults to false
            let root = NSView()
            root.addSubview(plain)
            #expect(MudOutputFindBar.findableTextView(in: root) == nil)
            #expect(MudOutputFindBar.findableTextView(in: nil) == nil)
        }
    }
#endif

#if os(macOS)
    import AppKit
    @testable import MudUI
    import Testing

    @MainActor
    @Suite("editbox dialog — scrollable text view config (#48)")
    struct ScriptDialogEditBoxTests {
        @Test("the text view is a properly resizable document view (so scrolling works)")
        func config() {
            let (scroll, textView) = ScriptDialogRunner.makeEditBox(text: "hi")
            #expect(scroll.documentView === textView)
            #expect(scroll.hasVerticalScroller)
            #expect(textView.string == "hi")
            // The properties whose absence caused the jerky/broken scrolling:
            #expect(textView.isVerticallyResizable)
            #expect(!textView.isHorizontallyResizable)
            #expect(textView.maxSize.height == CGFloat.greatestFiniteMagnitude)
            #expect(textView.textContainer?.widthTracksTextView == true)
            #expect(textView.textContainer?.containerSize.height == CGFloat.greatestFiniteMagnitude)
        }
    }
#endif

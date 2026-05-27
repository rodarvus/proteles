#if os(macOS)
    @testable import MudOutputView_macOS
    import Testing

    @Suite("SplitOutputContainer — live-tail visibility decision")
    struct SplitOutputContainerTests {
        private func show(
            doc: Double, originY: Double, height: Double, threshold: Double = 8
        ) -> Bool {
            SplitOutputContainer.shouldShowTail(
                documentHeight: doc,
                visibleOriginY: originY,
                visibleHeight: height,
                threshold: threshold
            )
        }

        @Test("Pinned to the bottom → no split")
        func atBottom() {
            // Viewport bottom (origin + height) == document height.
            #expect(show(doc: 1000, originY: 800, height: 200) == false)
        }

        @Test("Scrolled up past the threshold → split shown")
        func scrolledUp() {
            // 100pt from the bottom (> 8pt threshold).
            #expect(show(doc: 1000, originY: 700, height: 200) == true)
        }

        @Test("Within the threshold of the bottom → still no split (anti-flicker)")
        func withinSlop() {
            // 4pt from the bottom — under the 8pt threshold.
            #expect(show(doc: 1000, originY: 796, height: 200) == false)
        }

        @Test("Content shorter than the viewport → never split")
        func contentFits() {
            #expect(show(doc: 120, originY: 0, height: 400) == false)
        }
    }
#endif

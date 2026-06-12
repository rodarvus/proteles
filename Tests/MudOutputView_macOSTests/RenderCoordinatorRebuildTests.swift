#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    /// The #65 self-heal: re-attaching the coordinator rebuilds the text
    /// storage from the store snapshot — content preserved byte-for-byte,
    /// eviction FIFO consistent afterwards, and the frame stats carry the
    /// live document size the field instrumentation logs.
    @Suite("RenderCoordinator rebuild + document stats (#65)")
    @MainActor
    struct RenderCoordinatorRebuildTests {
        private func makeView() -> NSTextView? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let scrollView = NSTextView.scrollableTextView()
            guard let textView = scrollView.documentView as? NSTextView else { return nil }
            scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            window.contentView = scrollView
            return textView
        }

        @Test("frame stats carry the live document size")
        func statsCarryDocumentSize() async throws {
            let textView = try #require(makeView())
            let store = ScrollbackStore(maxLines: 100)
            let coordinator = RenderCoordinator(
                textView: textView, palette: .xtermDefault, frameInterval: .milliseconds(10)
            )
            let box = StatsBox()
            coordinator.onFrameFlush = { box.latest = $0 }
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<25 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(150))
            let stats = try #require(box.latest)
            #expect(stats.documentLines == 25)
            #expect(stats.documentUTF16Length == textView.textStorage?.length)
            #expect(stats.documentUTF16Length > 0)
        }

        @Test("re-attach rebuilds the storage identically; eviction stays consistent")
        func reattachRebuildsAndEvictionSurvives() async throws {
            let textView = try #require(makeView())
            let cap = 50
            let store = ScrollbackStore(maxLines: cap)
            let coordinator = RenderCoordinator(
                textView: textView, palette: .xtermDefault, frameInterval: .milliseconds(10)
            )
            await coordinator.attach(to: store)
            defer { coordinator.detach() }

            for index in 0..<80 { // past cap: eviction active
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(200))
            let before = textView.textStorage?.string ?? ""
            #expect(before.contains("line 79"))
            #expect(!before.contains("line 29\n")) // evicted

            // The self-heal path: re-attach to the same view.
            await coordinator.attach(to: store)
            try await Task.sleep(for: .milliseconds(100))
            let after = textView.textStorage?.string ?? ""
            #expect(after == before, "rebuild must reproduce the document exactly")

            // Eviction still aligned after the rebuild: more appends past cap
            // keep the document bounded and ordered.
            for index in 80..<120 {
                await store.append(text: "line \(index)")
            }
            try await Task.sleep(for: .milliseconds(200))
            let final = textView.textStorage?.string ?? ""
            #expect(final.contains("line 119"))
            #expect(!final.contains("line 69\n")) // evicted post-rebuild
            let lineCount = final.split(separator: "\n").count
            #expect(lineCount == cap)
        }
    }

    /// Single-slot stats holder for @Sendable callbacks.
    private final class StatsBox: @unchecked Sendable {
        var latest: RenderFrameStats?
    }
#endif

#if os(macOS)
    import AppKit
    import MudCore

    /// Bridges a ``ScrollbackStore`` to an `NSTextView`'s `NSTextStorage`
    /// with **render coalescing**: lines accumulate in a main-actor buffer
    /// and are flushed in a single `beginEditing` / `endEditing` transaction
    /// per frame (PLAN.md §6.3 / **D-01**).
    ///
    /// A burst of 100 inbound lines arriving in 100 ms therefore produces
    /// ≈6 layout passes, not 100.
    ///
    /// Frame ticker: a `Task` loop sleeping for one frame between flushes.
    /// Phase 1 uses ~60 Hz; a true display-link integration is a later
    /// refinement if profiling shows it matters.
    ///
    /// Auto-scroll: if the user was already within
    /// ``autoScrollThreshold`` points of the bottom when a flush starts,
    /// the view jumps to the new bottom after the append. Otherwise scroll
    /// position is preserved so the user can read older lines while new
    /// ones stream in.
    @MainActor
    public final class RenderCoordinator {
        /// Optional callback fired after every flush with the wall-clock
        /// duration the flush took. Used by the validation spike to measure
        /// frame timing without coupling to a logging framework.
        public var onFrameFlush: ((Duration) -> Void)?

        /// Distance from the bottom (in points) within which auto-scroll
        /// remains engaged.
        public var autoScrollThreshold: CGFloat = 32

        private weak var textView: NSTextView?
        private let builder: AttributedStringBuilder
        private let frameInterval: Duration
        private var pendingLines: [Line] = []
        private var subscriptionTask: Task<Void, Never>?
        private var frameTask: Task<Void, Never>?

        public init(
            textView: NSTextView,
            palette: ColorPalette = .xtermDefault,
            frameInterval: Duration = .milliseconds(16)
        ) {
            self.textView = textView
            let font = textView.font
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            builder = AttributedStringBuilder(palette: palette, font: font)
            self.frameInterval = frameInterval
        }

        nonisolated deinit {
            subscriptionTask?.cancel()
            frameTask?.cancel()
        }

        /// Subscribe to a ``ScrollbackStore`` and start the frame ticker.
        /// Safe to call repeatedly: each call detaches any previous binding
        /// first.
        public func attach(to store: ScrollbackStore) {
            detach()
            subscriptionTask = Task { [weak self] in
                let stream = await store.subscribe()
                for await line in stream {
                    await MainActor.run {
                        self?.enqueue(line)
                    }
                }
            }
            let interval = frameInterval
            frameTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    self?.flushPending()
                }
            }
        }

        /// Stop the frame ticker and cancel the store subscription. Safe to
        /// call when already detached.
        public func detach() {
            subscriptionTask?.cancel()
            subscriptionTask = nil
            frameTask?.cancel()
            frameTask = nil
        }

        // MARK: - Private

        private func enqueue(_ line: Line) {
            pendingLines.append(line)
        }

        private func flushPending() {
            guard !pendingLines.isEmpty,
                  let textView,
                  let storage = textView.textStorage
            else { return }

            let toAppend = pendingLines
            pendingLines.removeAll(keepingCapacity: true)

            let start = ContinuousClock.now
            let stickToBottom = isScrolledToBottom(textView)

            storage.beginEditing()
            for line in toAppend {
                storage.append(builder.build(line))
            }
            storage.endEditing()

            if stickToBottom {
                textView.scrollToEndOfDocument(nil)
            }

            onFrameFlush?(ContinuousClock.now - start)
        }

        private func isScrolledToBottom(_ textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else {
                return true
            }
            let contentHeight = scrollView.documentView?.frame.height ?? 0
            let visible = scrollView.contentView.documentVisibleRect
            let distanceFromBottom =
                contentHeight - (visible.origin.y + visible.height)
            return distanceFromBottom < autoScrollThreshold
        }
    }
#endif

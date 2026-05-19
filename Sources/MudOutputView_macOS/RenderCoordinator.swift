#if os(macOS)
    import AppKit
    import Collections
    import MudCore

    /// Bridges a ``ScrollbackStore`` to an `NSTextView`'s `NSTextStorage`
    /// with **render coalescing** and **eviction propagation**.
    ///
    /// Render coalescing (PLAN.md §6.3 / **D-01**): events accumulate in a
    /// main-actor buffer and are flushed in a single
    /// `beginEditing` / `endEditing` transaction per frame. A burst of 100
    /// inbound lines arriving in 100 ms therefore produces ≈6 layout passes,
    /// not 100.
    ///
    /// Eviction propagation: when ``ScrollbackStore`` exceeds its
    /// `maxLines` budget and drops the oldest in-memory line, the
    /// coordinator deletes the corresponding bytes from the head of
    /// `NSTextStorage`. Without this, `NSTextStorage` grows unbounded — the
    /// 57 MB-at-2000-lines spike result from Phase 1's D-04 study was
    /// almost entirely that.
    ///
    /// Frame ticker: a `Task` loop sleeping for one frame between flushes.
    /// Phase 1 chose this over `CADisplayLink` for simplicity; a true
    /// display-link integration is a later refinement only if profiling
    /// shows it matters.
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
        private var pendingEvents: [ScrollbackEvent] = []
        private var subscriptionTask: Task<Void, Never>?
        private var frameTask: Task<Void, Never>?

        /// FIFO of `(LineID, utf16Length)` for every line currently in
        /// `NSTextStorage`. On eviction, we pop from the head and delete
        /// exactly that many UTF-16 code units from the front of the
        /// storage — the result is that storage stays bounded by
        /// `ScrollbackStore.maxLines` characters worth of content.
        private var lineLengths: Deque<(id: LineID, utf16Length: Int)> = []

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
        ///
        /// `async` because the subscription must be installed before this
        /// returns — otherwise events yielded by the store while the
        /// internal subscription `Task` is still settling would be missed,
        /// and the coordinator's eviction-FIFO would drift out of sync
        /// with the store's eviction order.
        public func attach(to store: ScrollbackStore) async {
            detach()
            let stream = await store.events()
            subscriptionTask = Task { [weak self] in
                for await event in stream {
                    await MainActor.run {
                        self?.enqueue(event)
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

        private func enqueue(_ event: ScrollbackEvent) {
            pendingEvents.append(event)
        }

        private func flushPending() {
            guard !pendingEvents.isEmpty,
                  let textView,
                  let storage = textView.textStorage
            else { return }

            let toApply = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)

            let start = ContinuousClock.now
            let stickToBottom = isScrolledToBottom(textView)

            storage.beginEditing()

            // Coalesce contiguous evictions into a single
            // `deleteCharacters` call. The store always emits evictions in
            // append order, so a run of `.evicted` events corresponds to a
            // contiguous prefix of `NSTextStorage`.
            var pendingEvictBytes = 0

            for event in toApply {
                switch event {
                case .appended(let line):
                    if pendingEvictBytes > 0 {
                        storage.deleteCharacters(
                            in: NSRange(location: 0, length: pendingEvictBytes)
                        )
                        pendingEvictBytes = 0
                    }
                    let attributed = builder.build(line)
                    storage.append(attributed)
                    lineLengths.append((id: line.id, utf16Length: attributed.length))

                case .evicted(let id):
                    guard let head = lineLengths.popFirst() else { break }
                    assert(
                        head.id == id,
                        "ScrollbackStore eviction order does not match coordinator FIFO"
                    )
                    pendingEvictBytes += head.utf16Length
                }
            }

            if pendingEvictBytes > 0 {
                storage.deleteCharacters(
                    in: NSRange(location: 0, length: pendingEvictBytes)
                )
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

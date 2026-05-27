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

        /// Live-tail split (Mudlet-style): a small bottom pane that always shows
        /// the most recent lines while the user scrolls back through history.
        /// We keep the last ``tailLineCount`` rendered lines and mirror them
        /// into ``tailTextView`` whenever new output arrives. The pane's
        /// show/hide is owned by the view (``SplitOutputContainer``); here we
        /// only keep its content current.
        private weak var tailTextView: NSTextView?
        private var tailLineCount = 10
        private var recentLines: Deque<NSAttributedString> = []

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
            // Atomically grab the resident lines + a live event stream, then
            // render the existing buffer up front — so a freshly (re)created
            // view (e.g. after a font-size change) isn't blank.
            let (snapshot, stream) = await store.eventsWithSnapshot()
            renderSnapshot(snapshot)
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

        /// Wire the live-tail pane: `textView` will mirror the most recent
        /// `lineCount` lines of output. Call once, after construction.
        public func attachTail(textView: NSTextView, lineCount: Int) {
            tailTextView = textView
            tailLineCount = max(1, lineCount)
            refreshTail()
        }

        // MARK: - Private

        /// Render a batch of already-resident lines in one transaction (used on
        /// attach to restore the existing buffer). Mirrors the append path in
        /// ``flushPending`` but skips eviction handling (the snapshot is, by
        /// definition, within budget).
        private func renderSnapshot(_ lines: [Line]) {
            guard !lines.isEmpty, let textView, let storage = textView.textStorage else { return }
            storage.beginEditing()
            for line in lines {
                let attributed = builder.build(line)
                storage.append(attributed)
                lineLengths.append((id: line.id, utf16Length: attributed.length))
                recentLines.append(attributed)
            }
            if recentLines.count > tailLineCount {
                recentLines.removeFirst(recentLines.count - tailLineCount)
            }
            storage.endEditing()
            scrollToBottom(textView)
            refreshTail()
        }

        private func enqueue(_ event: ScrollbackEvent) {
            pendingEvents.append(event)
        }

        /// Re-render the live-tail pane from the buffered recent lines. The
        /// lines already carry a trailing newline (so the main view stacks
        /// them); we strip the final one so the tail isn't padded by a blank
        /// row at the bottom.
        private func refreshTail() {
            guard let storage = tailTextView?.textStorage else { return }
            let combined = NSMutableAttributedString()
            for line in recentLines {
                combined.append(line)
            }
            if combined.length > 0, combined.mutableString.hasSuffix("\n") {
                combined.deleteCharacters(in: NSRange(location: combined.length - 1, length: 1))
            }
            storage.setAttributedString(combined)
            tailTextView?.scrollToEndOfDocument(nil)
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
            var didAppend = false

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
                    recentLines.append(attributed)
                    if recentLines.count > tailLineCount {
                        recentLines.removeFirst(recentLines.count - tailLineCount)
                    }
                    didAppend = true

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
                scrollToBottom(textView)
            }
            if didAppend { refreshTail() }

            onFrameFlush?(ContinuousClock.now - start)
        }

        /// Pin the view to the bottom. We scroll immediately *and* again on the
        /// next runloop tick: TextKit lays text out asynchronously, so an
        /// immediate `scrollToEndOfDocument` can land short of the true end
        /// (the new lines aren't measured yet) — most visibly right after
        /// connect, when the first burst arrives before the view has sized. The
        /// deferred pass runs after layout settles and lands on the real bottom.
        private func scrollToBottom(_ textView: NSTextView) {
            textView.scrollToEndOfDocument(nil)
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollToEndOfDocument(nil)
            }
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

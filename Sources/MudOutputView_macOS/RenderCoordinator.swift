#if os(macOS)
    import AppKit
    import Collections
    import MudCore
    import os

    /// Bridges a ``ScrollbackStore`` to an `NSTextView`'s `NSTextStorage`
    /// with **render coalescing** and **eviction propagation**.
    ///
    /// Render coalescing (ARCHITECTURE.md §6.3 / **D-01**): events accumulate in a
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
    /// Per-flush render telemetry: how long the paint took, how much it painted,
    /// and — the key perf number — the worst **arrival→paint** latency among the
    /// lines shown this frame (`Date.now − line.timestamp`). Because `Line` is
    /// stamped at parse time (in `pipeline.consume`, *before* the GMCP-dispatch
    /// loop), that latency captures the whole path from "bytes arrived from the
    /// MUD" to "pixels on screen": GMCP-dispatch wait + queueing + frame wait +
    /// the flush itself. A high latency with a *low* `flushDuration` means the
    /// stall is upstream (processing), not the paint.
    public struct RenderFrameStats: Sendable {
        public let flushDuration: Duration
        public let appendedLines: Int
        public let maxArrivalLatency: TimeInterval
        /// Live document size after this flush (#65 follow-up): the line FIFO
        /// count and the NSTextStorage UTF-16 length. In the field these are
        /// the datum that separates "eviction broken → unbounded document"
        /// from "fixed-size document degrading" when flushes slow down.
        public let documentLines: Int
        public let documentUTF16Length: Int

        public init(
            flushDuration: Duration,
            appendedLines: Int,
            maxArrivalLatency: TimeInterval,
            documentLines: Int = 0,
            documentUTF16Length: Int = 0
        ) {
            self.flushDuration = flushDuration
            self.appendedLines = appendedLines
            self.maxArrivalLatency = maxArrivalLatency
            self.documentLines = documentLines
            self.documentUTF16Length = documentUTF16Length
        }
    }

    @MainActor
    public final class RenderCoordinator {
        public enum InitialScrollPosition: Sendable {
            case top
            case bottom
        }

        /// Optional callback fired after every flush with that frame's render
        /// telemetry (see ``RenderFrameStats``). Used by perf diagnosis (and the
        /// original validation spike) to measure timing without coupling to a
        /// logging framework.
        public var onFrameFlush: ((RenderFrameStats) -> Void)?

        /// Distance from the bottom (in points) within which auto-scroll
        /// remains engaged.
        public var autoScrollThreshold: CGFloat = 32

        /// Render-side eviction batching (#65 follow-up). The store evicts at
        /// its `maxLines` cap and emits one `.evicted` per line; naively we
        /// deleted that line from the TOP of the `NSTextStorage` on the same
        /// flush. But a delete at offset 0 invalidates TextKit 2's layout for
        /// the entire document, and the `scrollToEndOfDocument` that follows
        /// then estimates the end position over un-laid-out content — landing
        /// thousands of lines off and jumping the view, then crawling back as
        /// layout settles. The field signature is unmistakable: the jumping
        /// begins only after ~45–60 min, i.e. exactly when scrollback fills
        /// the cap and per-flush eviction starts.
        ///
        /// So we DEFER the top-delete: evicted lines stay rendered until
        /// `evictionBatch` of them accumulate, then we trim them in one edit —
        /// turning a per-flush invalidation into one per `evictionBatch` lines.
        /// (Mudlet does exactly this: `TBuffer.mBatchDeleteSize = 1000`.) The
        /// rendered document is bounded at the store's cap + `evictionBatch`.
        public var evictionBatch = 1000

        /// Number of leading ``lineLengths`` entries the store has evicted but
        /// we have not yet deleted from the `NSTextStorage` (see
        /// ``evictionBatch``). The first `evictionBacklog` rendered lines are
        /// logically gone; they're trimmed in one delete once a full batch
        /// accumulates.
        private var evictionBacklog = 0

        private weak var textView: NSTextView?
        private let builder: AttributedStringBuilder
        private let frameInterval: Duration
        private let initialScrollPosition: InitialScrollPosition
        /// Intake buffer between the off-main store subscription and the
        /// main-actor frame flush. The subscription pushes here WITHOUT hopping
        /// to the main actor per event, so a burst (e.g. resume seeding
        /// hundreds of lines via `appendBatch`) accumulates and the next flush
        /// renders it in ONE batch. (Previously the subscription did a
        /// `MainActor.run` per event; on a busy main actor those hops
        /// interleaved with the frame ticker, so a restored backlog trickled in
        /// one line per frame instead of filling in a single shot — #42/#65.)
        private let inbox = EventInbox()
        private var subscriptionTask: Task<Void, Never>?
        private var frameTask: Task<Void, Never>?

        /// Live-tail split (Mudlet-style): a small bottom pane that always shows
        /// the most recent lines while the user scrolls back through history.
        /// We retain the last ``tailRetained`` rendered lines and mirror them
        /// into ``tailTextView`` whenever new output arrives. We deliberately
        /// keep MORE lines than the pane shows at its default height so the user
        /// can *drag the pane taller* (``SplitOutputContainer``) to read more
        /// combat history without us re-plumbing the buffer — the pane height
        /// clips how many of the retained lines are visible. The pane's
        /// show/hide + size is owned by the view; here we only keep content current.
        private weak var tailTextView: NSTextView?
        private var tailRetained = 50
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
            initialScrollPosition: InitialScrollPosition = .bottom,
            frameInterval: Duration = .milliseconds(16)
        ) {
            self.textView = textView
            let font = textView.font
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            builder = AttributedStringBuilder(palette: palette, font: font)
            self.initialScrollPosition = initialScrollPosition
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
            // Clear any prior rendered state so attach is a full reset and is
            // safe to call on an already-populated view (e.g. a font-size
            // change re-creates the view, but a defensive reset keeps attach
            // idempotent regardless).
            if let storage = textView?.textStorage {
                storage.setAttributedString(NSAttributedString())
            }
            lineLengths.removeAll()
            recentLines.removeAll()
            inbox.clear()
            evictionBacklog = 0
            // Atomically grab the resident lines + a live event stream, then
            // render the existing buffer up front — so a freshly (re)created
            // view (e.g. after a font-size change) isn't blank.
            let (snapshot, stream) = await store.eventsWithSnapshot()
            renderSnapshot(snapshot)
            // Drain the stream OFF the main actor (Task.detached) into the
            // thread-safe inbox. This is the load-bearing detail: a plain
            // `Task {}` here would inherit this @MainActor method's isolation,
            // so its `for await` would run ON the main actor and interleave
            // with the frame ticker — flushing one event per frame (the
            // line-by-line resume trickle, #42/#65). Detached, a burst (resume
            // seeding via `appendBatch`) lands in the inbox at memory speed and
            // the next frame drains the whole thing in one flush.
            let inbox = inbox
            subscriptionTask = Task.detached {
                for await event in stream {
                    inbox.push(event)
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
            // Retain enough lines to fill a dragged-taller pane (see ``tailRetained``).
            tailRetained = max(50, lineCount)
            refreshTail()
        }

        // MARK: - Private

        /// Render a batch of already-resident lines in one transaction (used on
        /// attach to restore the existing buffer). Mirrors the append path in
        /// ``flushPending`` but skips eviction handling (the snapshot is, by
        /// definition, within budget).
        private func renderSnapshot(_ lines: [Line]) {
            guard !lines.isEmpty, let textView, let storage = textView.textStorage else { return }
            PerformanceProbe.shared.measure(
                "main-output.snapshot",
                events: lines.count,
                thresholdMS: 50
            ) {
                storage.beginEditing()
                for line in lines {
                    let attributed = builder.build(line)
                    storage.append(attributed)
                    lineLengths.append((id: line.id, utf16Length: attributed.length))
                    recentLines.append(attributed)
                }
                storage.endEditing()
            }
            if recentLines.count > tailRetained {
                recentLines.removeFirst(recentLines.count - tailRetained)
            }
            scroll(textView, to: initialScrollPosition)
            refreshTail()
        }

        /// Trim the deferred-eviction backlog in a single delete once it
        /// reaches a full ``evictionBatch``, so the layout-invalidating
        /// top-of-document delete happens once per batch rather than once per
        /// flush. Must be called inside the storage's `beginEditing` scope.
        private func trimEvictionBacklogIfFull(_ storage: NSTextStorage) {
            guard evictionBacklog >= evictionBatch else { return }
            PerformanceProbe.shared.measure(
                "main-output.eviction-trim",
                events: evictionBacklog,
                thresholdMS: 50
            ) {
                var evictBytes = 0
                for index in 0..<evictionBacklog {
                    evictBytes += lineLengths[index].utf16Length
                }
                storage.deleteCharacters(in: NSRange(location: 0, length: evictBytes))
                lineLengths.removeFirst(evictionBacklog)
                evictionBacklog = 0
            }
        }

        /// Remove newest rendered lines after a MUSHclient `DeleteLines` call.
        /// Must be called inside the storage's `beginEditing` scope.
        private func removeTail(_ ids: [LineID], from storage: NSTextStorage) {
            guard !ids.isEmpty else { return }
            for id in ids.reversed() {
                guard let tail = lineLengths.last, tail.id == id else { continue }
                let length = min(tail.utf16Length, storage.length)
                storage.deleteCharacters(in: NSRange(location: storage.length - length, length: length))
                lineLengths.removeLast()
                if !recentLines.isEmpty { recentLines.removeLast() }
            }
        }

        /// Re-render the live-tail pane from the buffered recent lines. The
        /// lines already carry a trailing newline (so the main view stacks
        /// them); we strip the final one so the tail isn't padded by a blank
        /// row at the bottom.
        private func refreshTail() {
            guard let storage = tailTextView?.textStorage else { return }
            PerformanceProbe.shared.measure(
                "main-output.tail-refresh",
                events: recentLines.count,
                thresholdMS: 50
            ) {
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
        }

        /// `render-flush` intervals for Instruments (#59 B5): the same window
        /// `RenderFrameStats.flushDuration` measures, visible on the
        /// timeline so flush stacking under burst load is observable on a
        /// live session. Free when nothing is recording.
        private static let signposter = OSSignposter(
            subsystem: "com.proteles", category: "render"
        )

        private func flushPending() {
            guard let textView, let storage = textView.textStorage else { return }
            let toApply = inbox.drain()
            guard !toApply.isEmpty else { return }
            let signpostState = Self.signposter.beginInterval("render-flush")
            defer { Self.signposter.endInterval("render-flush", signpostState) }

            let start = ContinuousClock.now
            let wallNow = Date()
            let stickToBottom = isScrolledToBottom(textView)
            var didAppend = false
            var didRemoveTail = false
            var appendedCount = 0
            var maxArrivalLatency: TimeInterval = 0

            PerformanceProbe.shared.measure(
                "main-output.storage-edit",
                events: toApply.count,
                thresholdMS: 50
            ) {
                storage.beginEditing()

                for event in toApply {
                    switch event {
                    case .appended(let line):
                        let attributed = builder.build(line)
                        storage.append(attributed)
                        lineLengths.append((id: line.id, utf16Length: attributed.length))
                        recentLines.append(attributed)
                        if recentLines.count > tailRetained {
                            recentLines.removeFirst(recentLines.count - tailRetained)
                        }
                        didAppend = true
                        appendedCount += 1
                        maxArrivalLatency = max(
                            maxArrivalLatency,
                            wallNow.timeIntervalSince(line.timestamp)
                        )

                    case .evicted(let id):
                        // Defer the top-delete (see ``evictionBatch``): the line
                        // stays rendered for now; we only advance the backlog
                        // cursor. The store evicts in append order, so the next
                        // eviction is always the first not-yet-deleted line,
                        // `lineLengths[evictionBacklog]`.
                        guard evictionBacklog < lineLengths.count else { break }
                        assert(
                            lineLengths[evictionBacklog].id == id,
                            "ScrollbackStore eviction order does not match coordinator FIFO"
                        )
                        evictionBacklog += 1

                    case .removedTail(let ids):
                        didRemoveTail = true
                        removeTail(ids, from: storage)
                    }
                }

                trimEvictionBacklogIfFull(storage)

                storage.endEditing()
            }

            if stickToBottom {
                scrollToBottom(textView)
            }
            if didAppend || didRemoveTail { refreshTail() }

            finishFlush(
                start: start,
                appendedCount: appendedCount,
                maxArrivalLatency: maxArrivalLatency,
                documentUTF16Length: storage.length
            )
        }

        /// Emit the frame telemetry (split from ``flushPending`` for the
        /// function-length budget). The live document size travels with every
        /// frame so a field session proves whether the rendered document
        /// stays capped (#65) — the datum that separates "eviction broken →
        /// unbounded document" from "fixed-size document degrading".
        private func finishFlush(
            start: ContinuousClock.Instant,
            appendedCount: Int,
            maxArrivalLatency: TimeInterval,
            documentUTF16Length: Int
        ) {
            let flushDuration = ContinuousClock.now - start
            onFrameFlush?(RenderFrameStats(
                flushDuration: flushDuration,
                appendedLines: appendedCount,
                maxArrivalLatency: maxArrivalLatency,
                documentLines: lineLengths.count,
                documentUTF16Length: documentUTF16Length
            ))
        }

        /// Pin the view to the bottom. We scroll immediately *and* again on the
        /// next runloop tick: TextKit lays text out asynchronously, so an
        /// immediate `scrollToEndOfDocument` can land short of the true end
        /// (the new lines aren't measured yet) — most visibly right after
        /// connect, when the first burst arrives before the view has sized. The
        /// deferred pass runs after layout settles and lands on the real bottom.
        private func scrollToBottom(_ textView: NSTextView) {
            PerformanceProbe.shared.measure(
                "main-output.scroll-bottom",
                events: 1,
                thresholdMS: 50
            ) {
                textView.scrollToEndOfDocument(nil)
            }
            DispatchQueue.main.async { [weak textView, weak self] in
                guard let textView, let self else { return }
                // Only pay the second scroll when the immediate one actually
                // landed short. `scrollToEndOfDocument` on a big document
                // walks TextKit 2's run storage to estimate the target
                // location (#65 — the 100%-CPU hang's hot frame), so the
                // common already-at-bottom case must be a cheap geometry
                // check, not a second walk.
                if !isScrolledToBottom(textView) {
                    PerformanceProbe.shared.measure(
                        "main-output.scroll-bottom-deferred",
                        events: 1,
                        thresholdMS: 50
                    ) {
                        textView.scrollToEndOfDocument(nil)
                    }
                }
            }
        }

        private func scroll(_ textView: NSTextView, to position: InitialScrollPosition) {
            switch position {
            case .top:
                scrollToTop(textView)
            case .bottom:
                scrollToBottom(textView)
            }
        }

        private func scrollToTop(_ textView: NSTextView) {
            guard let scrollView = textView.enclosingScrollView else { return }
            let origin = NSPoint(x: 0, y: 0)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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

    /// Thread-safe FIFO of scrollback events, filled by the off-main store
    /// subscription and drained by the main-actor frame flush. Decoupling
    /// intake from the frame rate is the point: a burst pushed faster than the
    /// frame interval (resume seeding, a reconnect dump) accumulates here and
    /// drains as ONE batch, instead of one-per-frame when each push had to hop
    /// the main actor and interleave with the ticker (#42/#65).
    private final class EventInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ScrollbackEvent] = []

        func push(_ event: ScrollbackEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        /// Return and clear everything buffered, in arrival order.
        func drain() -> [ScrollbackEvent] {
            lock.lock()
            defer { lock.unlock() }
            guard !events.isEmpty else { return [] }
            let drained = events
            events.removeAll(keepingCapacity: true)
            return drained
        }

        func clear() {
            lock.lock()
            events.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }
#endif

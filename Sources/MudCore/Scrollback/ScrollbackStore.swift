import Collections
import Foundation

/// One thing that happens to the scrollback. Subscribed via
/// ``ScrollbackStore/events()`` for callers that care about evictions
/// (chiefly the render coordinator, which must keep `NSTextStorage` in
/// sync with the in-memory line buffer).
public enum ScrollbackEvent: Sendable, Equatable {
    /// A new line was appended. Delivered in append order.
    case appended(Line)
    /// A previously-appended line was evicted because ``ScrollbackStore``
    /// hit its `maxLines` budget. Delivered in eviction order (FIFO with
    /// the original append order).
    case evicted(LineID)
    /// The newest resident lines were deleted by a scripting API such as
    /// MUSHclient `DeleteLines`. Delivered newest-last in the same order the
    /// lines appeared in the buffer.
    case removedTail([LineID])
}

/// Append-only line buffer with bounded in-memory capacity and a
/// monotonic ``LineID`` allocator (ARCHITECTURE.md §6.2).
///
/// Phase 1: in-memory only. Phase 2 adds eviction-event propagation so
/// the view layer's `NSTextStorage` stays bounded; SQLite-backed
/// persistence of evicted lines (ARCHITECTURE.md §8.3, §6.5) lands in a
/// subsequent commit.
///
/// Subscribers:
///   - ``subscribe()`` — `AsyncStream<Line>` of appended lines only.
///     Existing callers that don't care about evictions stay simple.
///   - ``events()`` — `AsyncStream<ScrollbackEvent>` of appends *and*
///     evictions, both in their respective FIFO orders.
///
/// Cancel either stream's iteration to unsubscribe.
public actor ScrollbackStore {
    /// Maximum number of lines retained in memory. Older lines are
    /// evicted on append.
    public let maxLines: Int

    private var lines: Deque<Line> = []
    private var nextLineRaw: UInt64 = 0
    private var lineSubscribers: [UUID: AsyncStream<Line>.Continuation] = [:]
    private var eventSubscribers: [UUID: AsyncStream<ScrollbackEvent>.Continuation] = [:]

    /// 100k field experiment (D-113): deliberately revisits the 10k safeguard
    /// from #65 so long live sessions retain substantially more history while
    /// the existing render-health instrumentation measures the TextKit cost.
    /// This is not yet a proven-safe production budget: the earlier 50k default
    /// eventually saturated the main thread during a six-hour combat session.
    /// Only the most recent tail is persisted to the flat JSONL sidecar for
    /// session resume (#42); there is no disk-backed infinite scrollback.
    public init(maxLines: Int = 100_000) {
        precondition(maxLines > 0, "maxLines must be positive")
        self.maxLines = maxLines
    }

    /// Append a line built from its parts. Returns the assigned ``LineID``.
    @discardableResult
    public func append(
        timestamp: Date = Date(),
        text: String,
        runs: [StyledRun] = []
    ) -> LineID {
        PerformanceProbe.shared.measure(
            "scrollback.append",
            events: 1,
            thresholdMS: 100
        ) {
            let id = LineID(nextLineRaw)
            nextLineRaw += 1
            appendLine(
                Line(id: id, timestamp: timestamp, text: text, runs: runs)
            )
            return id
        }
    }

    /// Append a fully-formed line. The line's `id` field is overridden
    /// with the store's next monotonic ID — callers can pass any
    /// placeholder ID.
    @discardableResult
    public func append(_ line: Line) -> LineID {
        PerformanceProbe.shared.measure(
            "scrollback.append",
            events: 1,
            thresholdMS: 100
        ) {
            let id = LineID(nextLineRaw)
            nextLineRaw += 1
            appendLine(
                Line(
                    id: id,
                    timestamp: line.timestamp,
                    text: line.text,
                    runs: line.runs
                )
            )
            return id
        }
    }

    /// Append many lines in a single actor hop (e.g. rebuilding a filtered view
    /// like the Channels panel). Each gets the next monotonic ID.
    public func appendBatch(_ newLines: [Line]) {
        PerformanceProbe.shared.measure(
            "scrollback.appendBatch",
            events: newLines.count,
            thresholdMS: 100
        ) {
            for line in newLines {
                let id = LineID(nextLineRaw)
                nextLineRaw += 1
                appendLine(
                    Line(
                        id: id,
                        timestamp: line.timestamp,
                        text: line.text,
                        runs: line.runs
                    )
                )
            }
        }
    }

    /// Current number of lines resident in memory.
    public var count: Int {
        lines.count
    }

    /// Total number of lines ever appended (including those evicted to
    /// keep the deque under ``maxLines``).
    public var totalAppended: UInt64 {
        nextLineRaw
    }

    /// Snapshot of all currently-resident lines in append order.
    public func snapshot() -> [Line] {
        Array(lines)
    }

    /// Snapshot of resident lines whose IDs fall within the closed range.
    /// Lines that have been evicted are silently absent.
    public func snapshot(in range: ClosedRange<LineID>) -> [Line] {
        lines.filter { range.contains($0.id) }
    }

    /// Delete up to `count` newest resident lines, used by MUSHclient
    /// `DeleteLines`. Returns the IDs removed in display order.
    @discardableResult
    public func removeLast(_ count: Int) -> [LineID] {
        guard count > 0, !lines.isEmpty else { return [] }
        let removeCount = Swift.min(count, lines.count)
        var removed: [LineID] = []
        removed.reserveCapacity(removeCount)
        for _ in 0..<removeCount {
            removed.append(lines.removeLast().id)
        }
        removed.reverse()
        for continuation in eventSubscribers.values {
            continuation.yield(.removedTail(removed))
        }
        return removed
    }

    /// Subscribe to newly-appended lines. The returned stream replays
    /// nothing — it begins delivering lines appended after subscription.
    /// Cancel iteration to unsubscribe.
    public func subscribe() -> AsyncStream<Line> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Line>.makeStream(
            bufferingPolicy: .unbounded
        )
        lineSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLineSubscriber(id) }
        }
        return stream
    }

    /// Subscribe to ``ScrollbackEvent``s — both appends and evictions.
    /// Use this when a downstream model needs to mirror the store's
    /// life cycle (the render coordinator, eventually scrollback
    /// persistence). Cancel iteration to unsubscribe.
    public func events() -> AsyncStream<ScrollbackEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ScrollbackEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return stream
    }

    /// Subscribe to ``ScrollbackEvent``s *and* atomically capture the lines
    /// already resident, in one actor hop. Use this when a fresh view must
    /// render the existing buffer and then stay live without missing or
    /// double-counting any line (the render coordinator on (re)attach — e.g.
    /// after a font-size change recreates the view). Cancel iteration to
    /// unsubscribe.
    public func eventsWithSnapshot() -> (snapshot: [Line], stream: AsyncStream<ScrollbackEvent>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ScrollbackEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return (Array(lines), stream)
    }

    // MARK: - Private

    private func appendLine(_ line: Line) {
        lines.append(line)
        for continuation in lineSubscribers.values {
            continuation.yield(line)
        }
        for continuation in eventSubscribers.values {
            continuation.yield(.appended(line))
        }
        while lines.count > maxLines {
            let evicted = lines.removeFirst()
            for continuation in eventSubscribers.values {
                continuation.yield(.evicted(evicted.id))
            }
        }
    }

    private func removeLineSubscriber(_ id: UUID) {
        lineSubscribers.removeValue(forKey: id)
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }
}

import Collections
import Foundation

/// Append-only line buffer with bounded in-memory capacity and a
/// monotonic ``LineID`` allocator (PLAN.md §6.2).
///
/// Phase 1: in-memory only. Phase 2 will persist evicted lines to SQLite
/// for full-session scrollback search (PLAN.md §8.3, §6.5).
///
/// Subscribers receive newly-appended lines via an unbounded
/// `AsyncStream<Line>`; cancel the stream's iteration to unsubscribe.
public actor ScrollbackStore {
    /// Maximum number of lines retained in memory. Older lines are
    /// evicted on append.
    public let maxLines: Int

    private var lines: Deque<Line> = []
    private var nextLineRaw: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<Line>.Continuation] = [:]

    public init(maxLines: Int = 50000) {
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
        let id = LineID(nextLineRaw)
        nextLineRaw += 1
        appendLine(
            Line(id: id, timestamp: timestamp, text: text, runs: runs)
        )
        return id
    }

    /// Append a fully-formed line. The line's `id` field is overridden
    /// with the store's next monotonic ID — callers can pass any
    /// placeholder ID.
    @discardableResult
    public func append(_ line: Line) -> LineID {
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

    /// Subscribe to newly-appended lines. The returned stream replays
    /// nothing — it begins delivering lines appended after subscription.
    /// Cancel iteration to unsubscribe.
    public func subscribe() -> AsyncStream<Line> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Line>.makeStream(
            bufferingPolicy: .unbounded
        )
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    // MARK: - Private

    private func appendLine(_ line: Line) {
        lines.append(line)
        while lines.count > maxLines {
            lines.removeFirst()
        }
        for continuation in subscribers.values {
            continuation.yield(line)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

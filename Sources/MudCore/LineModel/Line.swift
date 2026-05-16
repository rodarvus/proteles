import Foundation

/// Monotonically increasing identifier for a ``Line`` within a session.
///
/// IDs are assigned by ``ScrollbackStore`` and never reused within a
/// session. They survive eviction from the in-memory deque (Phase 2 will
/// persist evicted lines to SQLite under the same ID).
public struct LineID: Sendable, Equatable, Hashable, Comparable {
    public let raw: UInt64

    public init(_ raw: UInt64) {
        self.raw = raw
    }

    public static func < (lhs: LineID, rhs: LineID) -> Bool {
        lhs.raw < rhs.raw
    }
}

/// A single line of MUD output: the plain text plus the styled spans over
/// it. Lines are immutable once stored.
///
/// ``text`` is the line content with control characters already stripped;
/// it is what trigger engines match against (PLAN.md §6.2). ``runs`` are
/// styled spans whose ranges index into ``text`` as UTF-16 code units.
public struct Line: Sendable, Equatable {
    public let id: LineID
    public let timestamp: Date
    public let text: String
    public let runs: [StyledRun]

    public init(
        id: LineID,
        timestamp: Date = Date(),
        text: String,
        runs: [StyledRun] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.runs = runs
    }
}

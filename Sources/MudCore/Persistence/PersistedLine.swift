import Foundation
import GRDB

/// On-disk row type for a stored ``Line`` (PLAN.md §6.5, §8.3).
///
/// ``runsJSON`` is the JSON-encoded form of `[StyledRun]` — keeping it
/// in one TEXT column avoids a second table without losing the data we
/// need to re-render evicted lines if the user scrolls into the
/// persisted history.
///
/// `id` is **database-assigned** (nil until inserted): the first cut keyed
/// rows by the in-memory `LineID`, which restarts at 0 every app launch —
/// with `ON CONFLICT REPLACE`, each relaunch overwrote prior history from
/// id 0, and `mostRecent` (id DESC) returned the *oldest surviving* session
/// instead of the newest. That's how a session resume restored ten-hour-old
/// backlog (the 2026-06-11 incident).
public struct PersistedLine: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "scrollback_lines"

    public var id: Int64?
    public var timestamp: Date
    public var text: String
    public var runsJSON: String?

    public init(
        id: Int64? = nil,
        timestamp: Date,
        text: String,
        runsJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.runsJSON = runsJSON
    }

    /// Capture the database-assigned rowid after an insert.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case text
        case runsJSON = "runs_json"
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let timestamp = Column(CodingKeys.timestamp)
        public static let text = Column(CodingKeys.text)
        public static let runsJSON = Column(CodingKeys.runsJSON)
    }
}

// MARK: - Bridges to/from the in-memory Line model

public extension PersistedLine {
    /// Lossless projection of a ``Line`` into the on-disk form.
    init(_ line: Line) throws {
        let runsJSON: String?
        if line.runs.isEmpty {
            runsJSON = nil
        } else {
            let encoder = JSONEncoder()
            let data = try encoder.encode(line.runs)
            runsJSON = String(decoding: data, as: UTF8.self)
        }
        // The in-memory LineID is deliberately NOT the row key (it restarts
        // per launch); the database assigns ids, so insertion order is the
        // one true history order.
        self.init(
            timestamp: line.timestamp,
            text: line.text,
            runsJSON: runsJSON
        )
    }

    /// Reconstruct a ``Line`` from the on-disk form. Throws if the
    /// stored JSON is unparseable.
    func toLine() throws -> Line {
        let runs: [StyledRun]
        if let runsJSON, !runsJSON.isEmpty {
            let decoder = JSONDecoder()
            runs = try decoder.decode(
                [StyledRun].self,
                from: Data(runsJSON.utf8)
            )
        } else {
            runs = []
        }
        // Restored lines get placeholder ids — ScrollbackStore re-assigns
        // its own monotonic id on append anyway.
        return Line(
            id: LineID(UInt64(id ?? 0)),
            timestamp: timestamp,
            text: text,
            runs: runs
        )
    }
}

import Foundation
import GRDB

/// On-disk row type for a stored ``Line`` (PLAN.md §6.5, §8.3).
///
/// ``runsJSON`` is the JSON-encoded form of `[StyledRun]` — keeping it
/// in one TEXT column avoids a second table without losing the data we
/// need to re-render evicted lines if the user scrolls into the
/// persisted history.
public struct PersistedLine: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "scrollback_lines"

    public var id: Int64
    public var timestamp: Date
    public var text: String
    public var runsJSON: String?

    public init(
        id: Int64,
        timestamp: Date,
        text: String,
        runsJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.runsJSON = runsJSON
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
        self.init(
            id: Int64(line.id.raw),
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
        return Line(
            id: LineID(UInt64(id)),
            timestamp: timestamp,
            text: text,
            runs: runs
        )
    }
}

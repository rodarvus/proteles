import Foundation
import GRDB

/// On-disk row type for a stored ``ChatLine`` (#57 — chat survives crashes
/// and update relaunches the way scrollback does).
///
/// Mirrors ``PersistedLine``: `runsJSON` is the JSON-encoded `[StyledRun]`
/// of the already-styled message (Aardwolf `@`-codes resolved + linkified at
/// capture time), so a restore never re-parses colour codes. `id` is
/// **database-assigned** from day one — the scrollback v1 lesson (in-memory
/// ids restart per launch and REPLACE semantics overwrote history, the
/// 2026-06-11 stale-resume incident) is baked in here, not migrated to.
public struct PersistedChatLine: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat_lines"

    public var id: Int64?
    public var timestamp: Date
    public var channel: String
    public var sourceKind: String
    public var sourceName: String
    public var player: String
    public var text: String
    public var runsJSON: String?
    public var showsTimestamp: Bool

    public init(
        id: Int64? = nil,
        timestamp: Date,
        channel: String,
        sourceKind: String = "channel",
        sourceName: String? = nil,
        player: String,
        text: String,
        runsJSON: String? = nil,
        showsTimestamp: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.channel = channel
        self.sourceKind = sourceKind
        self.sourceName = sourceName ?? channel
        self.player = player
        self.text = text
        self.runsJSON = runsJSON
        self.showsTimestamp = showsTimestamp
    }

    /// Capture the database-assigned rowid after an insert.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case channel
        case sourceKind = "source_kind"
        case sourceName = "source_name"
        case player
        case text
        case runsJSON = "runs_json"
        case showsTimestamp = "shows_timestamp"
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let timestamp = Column(CodingKeys.timestamp)
        public static let channel = Column(CodingKeys.channel)
        public static let sourceKind = Column(CodingKeys.sourceKind)
        public static let sourceName = Column(CodingKeys.sourceName)
        public static let player = Column(CodingKeys.player)
        public static let text = Column(CodingKeys.text)
        public static let runsJSON = Column(CodingKeys.runsJSON)
        public static let showsTimestamp = Column(CodingKeys.showsTimestamp)
    }
}

// MARK: - Bridges to/from the in-memory ChatLine model

public extension PersistedChatLine {
    /// Lossless projection of a ``ChatLine`` into the on-disk form.
    init(_ chatLine: ChatLine) throws {
        let runsJSON: String?
        if chatLine.line.runs.isEmpty {
            runsJSON = nil
        } else {
            let data = try JSONEncoder().encode(chatLine.line.runs)
            runsJSON = String(decoding: data, as: UTF8.self)
        }
        self.init(
            timestamp: chatLine.timestamp,
            channel: chatLine.channel,
            sourceKind: chatLine.source.persistenceKind,
            sourceName: chatLine.source.name,
            player: chatLine.player,
            text: chatLine.line.text,
            runsJSON: runsJSON,
            showsTimestamp: chatLine.showsTimestamp
        )
    }

    /// Reconstruct the styled ``Line`` from the on-disk form. Throws if the
    /// stored JSON is unparseable.
    func toLine() throws -> Line {
        let runs: [StyledRun] = if let runsJSON, !runsJSON.isEmpty {
            try JSONDecoder().decode([StyledRun].self, from: Data(runsJSON.utf8))
        } else {
            []
        }
        // Placeholder id — ChatStore assigns its own monotonic id on restore.
        return Line(id: LineID(UInt64(id ?? 0)), timestamp: timestamp, text: text, runs: runs)
    }
}

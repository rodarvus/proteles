import Foundation
import GRDB

/// SQLite-backed chat log (#57) — ``ScrollbackDatabase``'s sibling for the
/// Chat window's capture, so channel history survives crashes and update
/// relaunches and is searchable across sessions.
///
/// Same threading model: a class (not an actor) because GRDB's
/// `DatabaseQueue` already serializes access; `Sendable` so
/// ``ChatPersistence`` (the actor that drives writes) can hold it.
///
/// **Retention.** Unlike scrollback (kept forever), chat is high-volume on
/// busy channels and much of it is ephemeral social traffic — rows older
/// than ``retentionDays`` are pruned once per open. Scrollback remains the
/// permanent record; the chat DB is the Chat window's working history.
public final class ChatDatabase: Sendable {
    public enum DatabaseError: Error, Equatable {
        case openFailed(String)
        case writeFailed(String)
        case readFailed(String)
    }

    /// On-disk path being used; useful for diagnostics.
    public let url: URL
    /// Rows older than this many days are pruned on open. `nil` keeps
    /// everything (tests; users who want a permanent chat archive can set it
    /// by hand once this is surfaced in Settings).
    public let retentionDays: Int?

    private let dbQueue: DatabaseQueue

    /// Open or create a database at `url`; migrations run on first access,
    /// then expired rows are pruned (a prune failure never blocks opening).
    public init(url: URL, retentionDays: Int? = 30) throws {
        self.url = url
        self.retentionDays = retentionDays
        do {
            let queue = try DatabaseQueue(path: url.path)
            dbQueue = queue
            try Self.migrator.migrate(queue)
        } catch {
            throw DatabaseError.openFailed(error.localizedDescription)
        }
        if let retentionDays {
            try? prune(olderThan: Date(timeIntervalSinceNow: -Double(retentionDays) * 86400))
        }
    }

    /// `~/Documents/Proteles/State/chat.sqlite` (#57). Creates the containing
    /// directory if needed.
    public static func defaultLocation(fileManager: FileManager = .default) throws -> URL {
        try ProtelesPaths.chatFile(fileManager: fileManager)
    }

    // MARK: - Writes

    /// Insert many lines in a single transaction (ids database-assigned,
    /// append-only).
    public func insertBatch(_ lines: [PersistedChatLine]) throws {
        guard !lines.isEmpty else { return }
        do {
            try dbQueue.write { db in
                for line in lines {
                    try line.insert(db)
                }
            }
        } catch {
            throw DatabaseError.writeFailed(error.localizedDescription)
        }
    }

    /// Delete rows with a timestamp before `cutoff` (the retention pass).
    public func prune(olderThan cutoff: Date) throws {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM chat_lines WHERE timestamp < ?",
                    arguments: [cutoff]
                )
            }
        } catch {
            throw DatabaseError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Reads

    /// Total number of lines stored.
    public func count() throws -> Int {
        do {
            return try dbQueue.read { db in
                try PersistedChatLine.fetchCount(db)
            }
        } catch {
            throw DatabaseError.readFailed(error.localizedDescription)
        }
    }

    /// The most recent `limit` lines, ordered oldest-first.
    public func mostRecent(limit: Int) throws -> [PersistedChatLine] {
        guard limit > 0 else { return [] }
        do {
            return try dbQueue.read { db in
                let descending = try PersistedChatLine
                    .order(PersistedChatLine.Columns.id.desc)
                    .limit(limit)
                    .fetchAll(db)
                return descending.reversed()
            }
        } catch {
            throw DatabaseError.readFailed(error.localizedDescription)
        }
    }

    /// Full-text search via FTS5 over the message text, optionally narrowed
    /// to one channel. AND semantics across words, like scrollback search.
    public func search(
        _ query: String,
        channel: String? = nil,
        limit: Int? = 200
    ) throws -> [PersistedChatLine] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try dbQueue.read { db in
                guard let pattern = FTS5Pattern(matchingAllTokensIn: trimmed)
                else { return [] }
                let channelFilter = channel != nil ? "AND chat_lines.channel = ?" : ""
                let sql = """
                SELECT chat_lines.*
                FROM chat_lines
                JOIN chat_lines_fts
                  ON chat_lines_fts.rowid = chat_lines.id
                WHERE chat_lines_fts MATCH ? \(channelFilter)
                ORDER BY chat_lines.id ASC
                \(limit.map { "LIMIT \($0)" } ?? "")
                """
                var arguments: [DatabaseValueConvertible] = [pattern]
                if let channel { arguments.append(channel) }
                return try PersistedChatLine.fetchAll(
                    db, sql: sql, arguments: StatementArguments(arguments)
                )
            }
        } catch {
            throw DatabaseError.readFailed(error.localizedDescription)
        }
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.chat_lines") { db in
            try db.create(table: "chat_lines") { table in
                table.column("id", .integer).primaryKey()
                table.column("timestamp", .datetime).notNull().indexed()
                table.column("channel", .text).notNull().indexed()
                table.column("player", .text).notNull()
                table.column("text", .text).notNull()
                table.column("runs_json", .text)
            }
            try db.create(virtualTable: "chat_lines_fts", using: FTS5()) { fts in
                fts.synchronize(withTable: "chat_lines")
                fts.tokenizer = .unicode61()
                fts.column("text")
            }
        }
        return migrator
    }
}

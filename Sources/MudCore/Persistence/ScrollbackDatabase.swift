import Foundation
import GRDB

/// SQLite-backed scrollback log (PLAN.md §6.5, §8.3).
///
/// Stores ``PersistedLine`` rows plus a synchronized FTS5 virtual table
/// over the `text` column. Search returns full lines so the caller can
/// re-render them at full fidelity (we keep ``StyledRun`` arrays as
/// JSON in the base row).
///
/// **Threading model.** `ScrollbackDatabase` is a class (not an actor)
/// because GRDB's `DatabaseQueue` already provides serialized,
/// thread-safe access. Wrapping it in another actor would add an
/// unnecessary hop. The type is `Sendable` so it can cross actor
/// boundaries freely — ``ScrollbackPersistence`` (the actor that
/// drives writes) holds a reference and calls through on its own
/// executor.
///
/// File layout: a single SQLite file. Phase 2 has one file per
/// installation; Phase 3 may split per-profile or per-session.
public final class ScrollbackDatabase: Sendable {
    /// Database errors with enough detail to surface to a user.
    public enum DatabaseError: Error, Equatable {
        case openFailed(String)
        case writeFailed(String)
        case readFailed(String)
    }

    /// On-disk path being used; useful for diagnostics.
    public let url: URL

    private let dbQueue: DatabaseQueue

    /// Open or create a database at `url`. Migrations run on first
    /// access; subsequent calls re-use the schema as-is.
    public init(url: URL) throws {
        self.url = url
        do {
            let queue = try DatabaseQueue(path: url.path)
            dbQueue = queue
            try Self.migrator.migrate(queue)
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.openFailed(error.localizedDescription)
        }
    }

    /// Convenience: open a database living under
    /// `~/Library/Application Support/com.proteles.ProtelesApp/`.
    /// Creates the containing directory if needed.
    public static func defaultLocation(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw DatabaseError.openFailed("no Application Support directory")
        }
        let folder = support.appendingPathComponent(
            "com.proteles.ProtelesApp",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder.appendingPathComponent("scrollback.sqlite")
    }

    // MARK: - Writes

    /// Insert (or replace) one line. Use ``insertBatch(_:)`` for many
    /// lines at once — batched writes are an order of magnitude faster
    /// because they share a single transaction.
    public func insert(_ line: PersistedLine) throws {
        do {
            try dbQueue.write { db in
                try line.insert(db, onConflict: .replace)
            }
        } catch {
            throw DatabaseError.writeFailed(error.localizedDescription)
        }
    }

    /// Insert many lines in a single transaction. Lines with IDs that
    /// already exist are replaced (`ON CONFLICT REPLACE` semantics).
    public func insertBatch(_ lines: [PersistedLine]) throws {
        guard !lines.isEmpty else { return }
        do {
            try dbQueue.write { db in
                for line in lines {
                    try line.insert(db, onConflict: .replace)
                }
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
                try PersistedLine.fetchCount(db)
            }
        } catch {
            throw DatabaseError.readFailed(error.localizedDescription)
        }
    }

    /// Return the most recent `limit` lines, ordered oldest-first.
    public func mostRecent(limit: Int) throws -> [PersistedLine] {
        guard limit > 0 else { return [] }
        do {
            return try dbQueue.read { db in
                let descending = try PersistedLine
                    .order(PersistedLine.Columns.id.desc)
                    .limit(limit)
                    .fetchAll(db)
                return descending.reversed()
            }
        } catch {
            throw DatabaseError.readFailed(error.localizedDescription)
        }
    }

    /// Full-text search via FTS5. Every word in `query` must appear
    /// in the matched line ("AND" semantics, which is what users
    /// expect from a quick search box). Phrases ("hello world") and
    /// other FTS5 operators are sanitised away by GRDB. Results come
    /// back oldest-first; `nil` `limit` means unlimited.
    public func search(
        _ query: String,
        limit: Int? = 200
    ) throws -> [PersistedLine] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try dbQueue.read { db in
                guard let pattern = FTS5Pattern(matchingAllTokensIn: trimmed)
                else { return [] }
                let sql = """
                SELECT scrollback_lines.*
                FROM scrollback_lines
                JOIN scrollback_lines_fts
                  ON scrollback_lines_fts.rowid = scrollback_lines.id
                WHERE scrollback_lines_fts MATCH ?
                ORDER BY scrollback_lines.id ASC
                \(limit.map { "LIMIT \($0)" } ?? "")
                """
                return try PersistedLine.fetchAll(
                    db,
                    sql: sql,
                    arguments: [pattern]
                )
            }
        } catch {
            throw DatabaseError.readFailed(error.localizedDescription)
        }
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.scrollback_lines") { db in
            try db.create(table: "scrollback_lines") { table in
                table.column("id", .integer).primaryKey()
                table.column("timestamp", .datetime).notNull().indexed()
                table.column("text", .text).notNull()
                table.column("runs_json", .text)
            }
            try db.create(
                virtualTable: "scrollback_lines_fts",
                using: FTS5()
            ) { fts in
                fts.synchronize(withTable: "scrollback_lines")
                fts.tokenizer = .unicode61()
                fts.column("text")
            }
        }

        return migrator
    }
}

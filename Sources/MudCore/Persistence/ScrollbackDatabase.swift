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

    /// `~/Documents/Proteles/State/scrollback.sqlite` (#43). Creates the
    /// containing directory if needed.
    public static func defaultLocation(
        fileManager: FileManager = .default
    ) throws -> URL {
        try ProtelesPaths.scrollbackFile(fileManager: fileManager)
    }

    // MARK: - Writes

    /// Insert (or replace) one line. Use ``insertBatch(_:)`` for many
    /// lines at once — batched writes are an order of magnitude faster
    /// because they share a single transaction.
    public func insert(_ line: PersistedLine) throws {
        do {
            try dbQueue.write { db in
                try line.insert(db)
            }
        } catch {
            throw DatabaseError.writeFailed(error.localizedDescription)
        }
    }

    /// Insert many lines in a single transaction. Ids are assigned by the
    /// database (append-only) — the first cut used the per-launch LineID
    /// with REPLACE semantics, which made every relaunch overwrite prior
    /// history from id 0 (the 2026-06-11 stale-resume incident).
    public func insertBatch(_ lines: [PersistedLine]) throws {
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

        // v1 keyed rows by the in-memory LineID (restarts at 0 per launch)
        // with REPLACE semantics: every relaunch overwrote prior history
        // from id 0, and the surviving rows' id order interleaved sessions —
        // so mostRecent (id DESC) returned the OLDEST surviving session.
        // That's how a session resume restored ten-hour-old backlog
        // (2026-06-11). Rebuild with fresh database-assigned ids in
        // timestamp order; ids are append-only from here on.
        migrator.registerMigration("v2.rekey_by_timestamp") { db in
            try db.execute(sql: "DROP TABLE scrollback_lines_fts")
            try db.execute(sql: """
            CREATE TABLE scrollback_lines_new (
                id INTEGER PRIMARY KEY,
                timestamp DATETIME NOT NULL,
                text TEXT NOT NULL,
                runs_json TEXT
            )
            """)
            try db.execute(sql: """
            INSERT INTO scrollback_lines_new (timestamp, text, runs_json)
            SELECT timestamp, text, runs_json FROM scrollback_lines
            ORDER BY timestamp, id
            """)
            // Dropping the old table also drops its FTS-sync triggers.
            try db.execute(sql: "DROP TABLE scrollback_lines")
            try db.execute(sql: "ALTER TABLE scrollback_lines_new RENAME TO scrollback_lines")
            try db.execute(sql: """
            CREATE INDEX scrollback_lines_on_timestamp ON scrollback_lines("timestamp")
            """)
            try db.create(
                virtualTable: "scrollback_lines_fts",
                using: FTS5()
            ) { fts in
                fts.synchronize(withTable: "scrollback_lines")
                fts.tokenizer = .unicode61()
                fts.column("text")
            }
            // synchronize() backfills from existing content, but make the
            // index state explicit + verifiable either way.
            try db.execute(
                sql: "INSERT INTO scrollback_lines_fts(scrollback_lines_fts) VALUES('rebuild')"
            )
        }

        // v3 (#66): the cold-path index cursor. The sidecar is the hot path
        // now; this records the highest sidecar `seq` already ingested, so a
        // launch after a crash knows exactly which sidecar entries the index
        // is missing.
        migrator.registerMigration("v3.meta") { db in
            try db.execute(sql: """
            CREATE TABLE proteles_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)
            """)
        }

        return migrator
    }

    // MARK: - Index cursor (#66)

    /// The highest sidecar sequence number already indexed, or nil if none.
    public func indexedThroughSeq() throws -> UInt64? {
        do {
            return try dbQueue.read { db in
                let value = try String.fetchOne(
                    db, sql: "SELECT value FROM proteles_meta WHERE key = 'indexed_seq'"
                )
                return value.flatMap(UInt64.init)
            }
        } catch {
            throw DatabaseError.readFailed(error.localizedDescription)
        }
    }

    /// One cold-path index transaction (#66): insert the batch AND advance
    /// the cursor atomically, so a crash can never leave the cursor ahead of
    /// the rows (behind is fine — reconciliation re-indexes, worst case a
    /// few duplicate rows from a torn batch, never lost ones).
    public func insertSidecarBatch(_ lines: [PersistedLine], through seq: UInt64) throws {
        do {
            try dbQueue.write { db in
                for line in lines {
                    try line.insert(db)
                }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO proteles_meta (key, value) VALUES ('indexed_seq', ?)",
                    arguments: [String(seq)]
                )
            }
        } catch {
            throw DatabaseError.writeFailed(error.localizedDescription)
        }
    }
}

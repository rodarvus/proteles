import Foundation
import GRDB

/// SQLite persistence for Search-and-Destroy's own data file (`SnDdb.db`),
/// kept in the per-profile world-data directory next to the mapper DB so the
/// vendored S&D Lua finds it at `GetInfo(66).."/SnDdb.db"`.
///
/// We create S&D's **final (`SCHEMA_VERSION = 6`) schema byte-for-byte** and
/// stamp `PRAGMA user_version = 6` on a fresh file, so S&D's own
/// `migrate_database()` sees a current database and never tries to `ALTER`
/// our tables. An imported or pre-existing file is left untouched (the
/// `CREATE TABLE IF NOT EXISTS` are no-ops) — S&D then migrates it itself if
/// it predates v6.
///
/// The point of this type is **import**: merging an existing `SnDdb.db`
/// (years of area/mob knowledge a player has built up, or a shared community
/// file) into the local one, additively — exactly the mapper's
/// `importIncremental` model. We never overwrite local rows.
///
/// Threading: a `Sendable` class over GRDB's serialized `DatabaseQueue`
/// (same model as ``MapperStore``).
public final class SearchAndDestroyStore: Sendable {
    public enum StoreError: Error, Equatable {
        case openFailed(String)
        case readFailed(String)
        case writeFailed(String)
    }

    /// S&D's final schema version (`core.lua`'s `SCHEMA_VERSION`).
    public static let schemaVersion = 6

    public let url: URL
    private let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        self.url = url
        do {
            // WAL so S&D's lsqlite3 connection can read/write the same file
            // (a second connection) without blocking ours. Set per connection
            // before use — `PRAGMA journal_mode` can't run in a transaction.
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                // Wait out a concurrent writer (S&D's lsqlite3 connection) on
                // import rather than failing immediately with SQLITE_BUSY.
                try db.execute(sql: "PRAGMA busy_timeout = 5000")
            }
            dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
            try Self.ensureSchema(dbQueue)
        } catch {
            throw StoreError.openFailed(error.localizedDescription)
        }
    }

    /// The global S&D database, `~/Documents/Proteles/Databases/SnDdb.db` — the
    /// same file the host opens via `GetInfo(66)` (its configured directory).
    /// Area/mob data is world-wide, so it's shared across characters (D-59).
    public static func defaultStoreURL(fileManager: FileManager = .default) throws -> URL {
        try ProtelesPaths.searchAndDestroyDatabaseURL(fileManager: fileManager)
    }

    /// Area keys for `runto <area>` argument completion (#32) — the short
    /// identifiers S&D navigates by (`key` + the user's `userKey`), deduped +
    /// sorted. Read-only; safe to call alongside S&D's own connection.
    public func areaCompletions() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, userKey FROM area")
            var seen = Set<String>()
            var result: [String] = []
            for row in rows {
                for value: String? in [row["key"], row["userKey"]] {
                    let key = value?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !key.isEmpty, seen.insert(key.lowercased()).inserted { result.append(key) }
                }
            }
            return result.sorted()
        }
    }

    // MARK: - Schema

    /// Create S&D's v6 schema on a fresh file and stamp `user_version = 6`.
    /// If `mobs` already exists the file is left exactly as found (it may be
    /// an older S&D DB that S&D itself will migrate).
    private static func ensureSchema(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            let fresh = try !tableExists(db, "mobs")
            guard fresh else { return }

            // Final post-migration shape (mobs gains seen_count/kill_count at
            // v3, the mob_keyword_exceptions table at v2, history at v6).
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mobs (
              mob        TEXT NOT NULL COLLATE NOCASE,
              room       TEXT NOT NULL COLLATE NOCASE,
              roomid     INTEGER NOT NULL,
              zone       TEXT NOT NULL,
              seen_count INTEGER NOT NULL DEFAULT 0,
              kill_count INTEGER NOT NULL DEFAULT 0,
              UNIQUE(mob, roomid)
            );
            CREATE TABLE IF NOT EXISTS area (
              name      TEXT NOT NULL,
              key       TEXT NOT NULL,
              minlvl    INTEGER NOT NULL,
              maxlvl    INTEGER NOT NULL,
              lock      INTEGER NOT NULL,
              startRoom INTEGER,
              noquest   TEXT,
              vidblain  TEXT,
              userKey   TEXT
            );
            CREATE TABLE IF NOT EXISTS mob_keyword_exceptions (
              area_name TEXT NOT NULL,
              mob_name  TEXT NOT NULL,
              keyword   TEXT NOT NULL,
              UNIQUE(area_name, mob_name)
            );
            CREATE TABLE IF NOT EXISTS history (
              id            INTEGER PRIMARY KEY,
              type          INTEGER NOT NULL,
              level_taken   INTEGER NOT NULL,
              start_time    INTEGER NOT NULL,
              end_time      INTEGER,
              status        INTEGER DEFAULT 1,
              qp_rewards    INTEGER DEFAULT 0,
              tp_rewards    INTEGER DEFAULT 0,
              train_rewards INTEGER DEFAULT 0,
              prac_rewards  INTEGER DEFAULT 0,
              gold_rewards  INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS mobs_zone_mob_room ON mobs (zone, mob, room);
            CREATE INDEX IF NOT EXISTS area_key ON area (key);
            CREATE INDEX IF NOT EXISTS history_start_time_type ON history (start_time, type);
            CREATE INDEX IF NOT EXISTS history_type_status ON history (type, status);
            CREATE INDEX IF NOT EXISTS history_end_time_status_type
              ON history (end_time, status, type);
            """)
            try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT count(*) > 0 FROM sqlite_master WHERE type='table' AND name=?",
            arguments: [name]
        ) ?? false
    }

    /// Existence of a table in the attached import source (`importsrc`).
    private static func sourceTableExists(_ db: Database, _ name: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT count(*) > 0 FROM importsrc.sqlite_master WHERE type='table' AND name=?",
            arguments: [name]
        ) ?? false
    }

    /// Column names of a table in the attached import source.
    private static func sourceColumnNames(_ db: Database, of table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA importsrc.table_info(\(table))")
        return Set(rows.compactMap { $0["name"] as String? })
    }

    // MARK: - Import

    public struct ImportSummary: Sendable, Equatable {
        public var mobs = 0
        public var areas = 0
        public var keywords = 0
        public var history = 0

        public var total: Int {
            mobs + areas + keywords + history
        }

        public var isEmpty: Bool {
            total == 0
        }
    }

    public enum ImportError: Error, Equatable {
        /// The chosen file isn't a recognisable Search-and-Destroy database.
        case notASearchAndDestroyDatabase
    }

    /// Incrementally merge another `SnDdb.db` into this one — *adds what we
    /// don't already have* and never overwrites local rows. Tolerant of older
    /// S&D schemas (a pre-v3 `mobs.count` column maps to `seen_count`).
    /// Returns the per-table counts of newly inserted rows.
    public func importIncremental(from source: URL) throws -> ImportSummary {
        do {
            // ATTACH/DETACH can't run inside a transaction, so drive the
            // connection without GRDB's implicit one and wrap just the inserts.
            return try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "ATTACH DATABASE ? AS importsrc", arguments: [source.path])
                defer { try? db.execute(sql: "DETACH DATABASE importsrc") }
                var summary = ImportSummary()
                try db.inTransaction {
                    summary = try Self.merge(into: db)
                    return .commit
                }
                return summary
            }
        } catch let error as ImportError {
            throw error
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Delete all S&D content (mobs, areas, keyword exceptions, history),
    /// leaving the schema intact. A development/testing affordance so the
    /// database can be reset to empty and re-imported.
    public func empty() throws {
        do {
            try dbQueue.write { db in
                for table in ["mobs", "area", "mob_keyword_exceptions", "history"] {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private static func merge(into db: Database) throws -> ImportSummary {
        // An S&D DB has at least a `mobs` table.
        guard try sourceTableExists(db, "mobs") else {
            throw ImportError.notASearchAndDestroyDatabase
        }

        var summary = ImportSummary()
        summary.mobs = try mergeMobs(db)
        summary.areas = try mergeAreas(db)
        summary.keywords = try insertIgnore(
            db,
            table: "mob_keyword_exceptions",
            columns: "area_name, mob_name, keyword"
        )
        summary.history = try insertIgnore(
            db,
            table: "history",
            columns: """
            id, type, level_taken, start_time, end_time, status, \
            qp_rewards, tp_rewards, train_rewards, prac_rewards, gold_rewards
            """
        )
        return summary
    }

    /// Merge `mobs`, mapping older schemas: a source with only `count` (pre-v3)
    /// supplies `seen_count`; a missing `kill_count` defaults to 0. Deduped by
    /// the `UNIQUE(mob, roomid)` constraint via `INSERT OR IGNORE`.
    private static func mergeMobs(_ db: Database) throws -> Int {
        let columns = try sourceColumnNames(db, of: "mobs")
        let seen = columns.contains("seen_count") ? "seen_count"
            : columns.contains("count") ? "count" : "0"
        let kill = columns.contains("kill_count") ? "kill_count" : "0"
        try db.execute(sql: """
        INSERT OR IGNORE INTO mobs (mob, room, roomid, zone, seen_count, kill_count)
        SELECT mob, room, roomid, zone, \(seen), \(kill) FROM importsrc.mobs
        """)
        return db.changesCount
    }

    /// Merge `area`. The table carries no unique constraint (S&D's own
    /// schema), so dedupe with an anti-join on the area `key`.
    private static func mergeAreas(_ db: Database) throws -> Int {
        guard try sourceTableExists(db, "area") else { return 0 }
        try db.execute(sql: """
        INSERT INTO area (name, key, minlvl, maxlvl, lock, startRoom, noquest, vidblain, userKey)
        SELECT name, key, minlvl, maxlvl, lock, startRoom, noquest, vidblain, userKey
        FROM importsrc.area
        WHERE key NOT IN (SELECT key FROM area)
        """)
        return db.changesCount
    }

    /// `INSERT OR IGNORE INTO <table> (cols) SELECT cols FROM importsrc.<table>`,
    /// returning rows actually inserted. A table missing from the source
    /// contributes zero.
    private static func insertIgnore(_ db: Database, table: String, columns: String) throws -> Int {
        guard try sourceTableExists(db, table) else { return 0 }
        try db.execute(sql: """
        INSERT OR IGNORE INTO \(table) (\(columns))
        SELECT \(columns) FROM importsrc.\(table)
        """)
        return db.changesCount
    }

    // MARK: - Reads (counts, for diagnostics + tests)

    /// Row count of a managed table (`mobs`/`area`/`mob_keyword_exceptions`/
    /// `history`), or 0 if it doesn't exist.
    public func count(of table: String) throws -> Int {
        do {
            return try dbQueue.read { db in
                guard try Self.tableExists(db, table) else { return 0 }
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
            }
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    /// The stamped `user_version` (6 on a DB we created fresh).
    public func userVersion() throws -> Int {
        do {
            return try dbQueue.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            }
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }
}

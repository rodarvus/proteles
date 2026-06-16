import Foundation
import GRDB

/// The per-character mapper **overlay** (D-111). The shared `Aardwolf.db` holds
/// the world map (rooms, areas, cardinal exits); this overlay
/// (`Databases/<character>/Aardwolf-personal.db`) holds only one character's
/// personal data — portals, custom exits, exit level-locks, room notes,
/// bookmarks — so it never bleeds across characters.
///
/// Routing: per-character writes/reads go through ``personalWrite(_:)`` /
/// ``personalRead(_:)``, which **fall back to the shared queue when no overlay
/// is attached** (single-file / pre-character) — so an un-migrated DB behaves
/// byte-for-byte as it did before the split. The two databases are merged in
/// Swift by ``mergePersonalOverlay(into:)`` (no cross-database JOIN; navigation
/// stays in-memory).
extension MapperStore {
    /// WAL + busy-timeout config, shared by both connections. WAL so a plugin's
    /// lsqlite3 reader can read the map while we write it; busy-timeout waits
    /// out a concurrent reader/writer rather than failing with SQLITE_BUSY.
    /// (PRAGMA journal_mode can't run inside a transaction, so it's set per
    /// connection via `prepareDatabase`.)
    static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        return configuration
    }

    /// True when a per-character overlay is attached (vs. single-file mode).
    var hasPersonalStore: Bool {
        personalQueue != nil
    }

    /// Write against the per-character overlay, falling back to the shared queue
    /// when no overlay is attached (D-111).
    func personalWrite<T>(_ block: (Database) throws -> T) throws -> T {
        do { return try (personalQueue ?? dbQueue).write(block) } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Read from the per-character overlay, falling back to the shared queue
    /// when no overlay is attached (D-111).
    func personalRead<T>(_ block: (Database) throws -> T) throws -> T {
        do { return try (personalQueue ?? dbQueue).read(block) } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    /// Create the per-character overlay schema (D-111): the per-character
    /// `exits` rows (portals + custom exits), the `exit_locks` level-override
    /// table (locks can't move — they're a column on shared cardinal-exit rows),
    /// plus `bookmarks` (room notes), `room_user_data`, `storage`, and
    /// `proteles_meta`. `IF NOT EXISTS` so re-opening an overlay is a no-op.
    static func ensurePersonalSchema(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS exits (
              dir TEXT NOT NULL, fromuid TEXT NOT NULL, touid TEXT NOT NULL,
              level STRING NOT NULL DEFAULT '0', weight INTEGER, door INTEGER,
              PRIMARY KEY(fromuid, dir));
            CREATE TABLE IF NOT EXISTS exit_locks (
              fromuid TEXT NOT NULL, dir TEXT NOT NULL, level STRING NOT NULL DEFAULT '0',
              PRIMARY KEY(fromuid, dir));
            CREATE TABLE IF NOT EXISTS bookmarks (uid TEXT NOT NULL, notes TEXT, PRIMARY KEY(uid));
            CREATE TABLE IF NOT EXISTS room_user_data (
              uid TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY(uid, key));
            CREATE TABLE IF NOT EXISTS storage (name TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(name));
            CREATE TABLE IF NOT EXISTS proteles_meta (key TEXT NOT NULL, value TEXT, PRIMARY KEY(key));
            CREATE INDEX IF NOT EXISTS personal_exits_touid ON exits (touid);
            """)
            try db.execute(
                sql: "INSERT OR REPLACE INTO proteles_meta(key, value) VALUES('schema_version', ?)",
                arguments: [String(protelesSchemaVersion)]
            )
        }
    }

    /// What ``splitPersonal(sharedURL:overlayURL:)`` moved out of the shared map.
    struct SplitSummary: Sendable, Equatable {
        public var portals = 0
        public var customExits = 0
        public var exitLocks = 0
        public var notes = 0
        public var alreadySplit = false
    }

    /// `proteles_meta` flag stamped in the shared DB once it has been split, so
    /// the split is idempotent and the live mapper knows the overlay is safe to
    /// attach (no "State B" double-counting). D-111.
    static let personalSplitKey = "personal_split"

    /// Split a single-file mapper DB (everything in `sharedURL`) into the shared
    /// world map + a per-character overlay (D-111): move portals, custom exits,
    /// cardinal exit-locks, and room notes (`bookmarks`) out of the shared file
    /// into `overlayURL`, leaving the shared file canonical (cardinals at level
    /// 0). Used by **both** import demux (Phase 3) and migration (Phase 4).
    ///
    /// Idempotent: a shared DB already flagged split is left untouched. Order is
    /// overlay-write → shared-delete → flag, so a mid-way failure leaves the
    /// flag unset (still single-file/State A) and re-running is safe (overlay
    /// upserts, shared deletes by predicate).
    @discardableResult
    static func splitPersonal(sharedURL: URL, overlayURL: URL) throws -> SplitSummary {
        let store = try MapperStore(url: sharedURL, personalURL: overlayURL)
        if (try? store.meta(forKey: personalSplitKey)) == "1" {
            return SplitSummary(alreadySplit: true)
        }
        // Partition the shared exits in Swift (one full read; import/migration
        // is a one-time op). Portals + customs become overlay rows; a non-zero
        // cardinal level becomes an overlay exit-lock.
        var summary = SplitSummary()
        let rows = try store.read { db in try Row.fetchAll(db, sql: "SELECT * FROM exits") }
        let notes = try store.read { db in
            try Row.fetchAll(db, sql: "SELECT uid, notes FROM bookmarks")
        }
        try store.personalWrite { db in
            for row in rows {
                guard let from = row["fromuid"] as String?, let dir = row["dir"] as String? else { continue }
                if from == "*" || from == "**" {
                    try insertOverlayExit(db, row); summary.portals += 1
                } else if !isCardinal(dir) {
                    try insertOverlayExit(db, row); summary.customExits += 1
                } else if levelInt(row, "level") > 0 {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO exit_locks (fromuid, dir, level) VALUES (?, ?, ?)",
                        arguments: [from, dir, String(levelInt(row, "level"))]
                    )
                    summary.exitLocks += 1
                }
            }
            for note in notes where (note["notes"] as String?)?.isEmpty == false {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO bookmarks (uid, notes) VALUES (?, ?)",
                    arguments: [note["uid"] as String? ?? "", note["notes"] as String?]
                )
                summary.notes += 1
            }
        }
        try store.write { db in
            try db.execute(sql: "DELETE FROM exits WHERE fromuid IN ('*','**')")
            try db.execute(sql: "DELETE FROM exits WHERE NOT \(cardinalInClause)")
            try db.execute(sql: "UPDATE exits SET level = '0' WHERE \(cardinalInClause) AND level != '0'")
            try db.execute(sql: "DELETE FROM bookmarks")
        }
        try store.setMeta("1", forKey: personalSplitKey)
        return summary
    }

    /// Whether this (single-file) shared DB still holds per-character data a
    /// migration would move out — i.e. it predates the split *and* isn't empty
    /// of personals. False once split (the `personal_split` flag) or for a fresh
    /// map. Drives the one-time migration prompt (D-111).
    func needsPersonalMigration() -> Bool {
        if (try? meta(forKey: Self.personalSplitKey)) == "1" { return false }
        return (try? read { db in
            let portalsOrCustoms = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM exits WHERE fromuid IN ('*','**') OR NOT \(Self.cardinalInClause)
            """) ?? 0
            let locks = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM exits WHERE \(Self.cardinalInClause) AND level != '0'"
            ) ?? 0
            let notes = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM bookmarks WHERE notes IS NOT NULL AND notes != ''"
            ) ?? 0
            return portalsOrCustoms + locks + notes > 0
        }) ?? false
    }

    /// Migrate an existing single-file mapper DB in place (D-111, Phase 4):
    /// **back up the shared file first** (a clean `VACUUM INTO` snapshot — WAL-
    /// safe, unlike a raw file copy), then `splitPersonal` it into the overlay.
    /// Non-destructive: the backup is written before any change, and the split
    /// itself is idempotent. Returns the split summary (`alreadySplit` when the
    /// DB was migrated previously — the backup is still refreshed).
    @discardableResult
    static func migratePersonal(
        sharedURL: URL, overlayURL: URL, backupURL: URL
    ) throws -> SplitSummary {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: backupURL.path) { try fileManager.removeItem(at: backupURL) }
        let queue = try DatabaseQueue(path: sharedURL.path, configuration: makeConfiguration())
        try queue.writeWithoutTransaction { db in
            let escaped = backupURL.path.replacingOccurrences(of: "'", with: "''")
            try db.execute(sql: "VACUUM INTO '\(escaped)'")
        }
        return try splitPersonal(sharedURL: sharedURL, overlayURL: overlayURL)
    }

    /// Copy one `exits` row (preserving level/weight/door) into the overlay.
    private static func insertOverlayExit(_ db: Database, _ row: Row) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO exits (dir, fromuid, touid, level, weight, door)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                row["dir"] as String? ?? "", row["fromuid"] as String? ?? "",
                row["touid"] as String? ?? "", String(levelInt(row, "level")),
                row["weight"] as Int?, row["door"] as Int?
            ]
        )
    }

    /// Fold the per-character overlay into a graph loaded from the shared map:
    /// the character's own `exits` rows (portals + custom exits), the
    /// `exit_locks` level overrides on shared cardinal exits, and the
    /// character's room notes (`bookmarks`). Pure dictionary merge.
    func mergePersonalOverlay(into graph: inout RoomGraph) throws {
        try personalRead { db in
            for row in try Row.fetchAll(db, sql: "SELECT * FROM exits") {
                guard let from = row["fromuid"] as String? else { continue }
                let exit = Self.exit(from: row)
                graph.rooms[from, default: Room(uid: from)].exits[exit.dir] = exit
            }
            for row in try Row.fetchAll(db, sql: "SELECT fromuid, dir, level FROM exit_locks") {
                guard let from = row["fromuid"] as String?, let dir = row["dir"] as String? else { continue }
                graph.rooms[from]?.exits[dir]?.level = Self.levelInt(row, "level")
            }
            for row in try Row.fetchAll(db, sql: "SELECT uid, notes FROM bookmarks") {
                if let uid = row["uid"] as String? { graph.rooms[uid]?.notes = row["notes"] as String? }
            }
        }
    }
}

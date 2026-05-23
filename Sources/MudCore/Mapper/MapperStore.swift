import Foundation
import GRDB

/// SQLite persistence for the map (PLAN.md §7.7). Deliberately uses the
/// **MUSHclient mapper schema as a read-compatible superset** so that:
///   - importing an existing `Aardwolf.db` is just opening it (we add our
///     extension tables/columns non-destructively, handling DBs at
///     `user_version` 2–11 defensively), and
///   - plugins that read the mapper DB directly (e.g. Search-and-Destroy,
///     which `SELECT`s `rooms`/`areas`/`exits`/`bookmarks` by name) keep
///     working against the same file we write.
///
/// Base tables (`rooms`/`areas`/`exits`/`bookmarks`/`environments`/
/// `terrain`/`storage`) keep their MUSHclient column names byte-for-byte.
/// Proteles extensions are additive: `proteles_meta` (our schema version),
/// `room_user_data` (KV), and `exits.weight`/`exits.door`.
///
/// Threading: a `Sendable` class over GRDB's serialized `DatabaseQueue`
/// (same model as ``ScrollbackDatabase``); the ``Mapper`` actor drives it.
public final class MapperStore: Sendable {
    public enum StoreError: Error, Equatable {
        case openFailed(String)
        case readFailed(String)
        case writeFailed(String)
    }

    public let url: URL
    private let dbQueue: DatabaseQueue

    /// Our extension-schema version, stamped in `proteles_meta` (orthogonal
    /// to the MUSHclient `user_version`, which stays at the imported value).
    public static let protelesSchemaVersion = 1

    public init(url: URL) throws {
        self.url = url
        do {
            // WAL so a plugin's lsqlite3 reader can read the map while we
            // write it (a second connection); rollback-journal mode would
            // block concurrent access. Set on each connection before use
            // (PRAGMA journal_mode can't run inside a transaction).
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                // Wait out a concurrent reader/writer (a plugin's lsqlite3
                // connection) rather than failing with SQLITE_BUSY.
                try db.execute(sql: "PRAGMA busy_timeout = 5000")
            }
            dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
            try Self.ensureSchema(dbQueue)
        } catch {
            throw StoreError.openFailed(error.localizedDescription)
        }
    }

    /// Legacy per-world DB location (pre-world-data-dir):
    /// `…/com.proteles.ProtelesApp/mapper/<id>.db`. Kept as the migration
    /// source for ``worldDatabaseURL(forProfile:worldName:)``.
    public static func defaultStoreURL(
        forProfile id: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        let folder = try appSupport(fileManager)
            .appendingPathComponent("mapper", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString).db")
    }

    /// Per-profile world-data directory — the single place the mapper DB and
    /// MUSHclient-compat plugins' own SQLite stores live (this is what
    /// `GetInfo(66)` resolves to). `…/com.proteles.ProtelesApp/worlds/<id>/`.
    public static func worldDataDirectory(
        forProfile id: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        let folder = try appSupport(fileManager)
            .appendingPathComponent("worlds", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The mapper DB inside the world-data directory, named `<worldName>.db`
    /// so plugins find it at `GetInfo(66)..WorldName()..".db"`. Migrates a
    /// pre-existing legacy `mapper/<id>.db` here on first use.
    public static func worldDatabaseURL(
        forProfile id: UUID,
        worldName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try worldDataDirectory(forProfile: id, fileManager: fileManager)
        let target = directory.appendingPathComponent("\(worldName).db")
        if let legacy = try? defaultStoreURL(forProfile: id, fileManager: fileManager) {
            migrateDatabaseIfNeeded(from: legacy, to: target, fileManager: fileManager)
        }
        return target
    }

    /// Move a legacy DB to `target` only when `target` doesn't yet exist and
    /// the legacy file does (idempotent; moves the `-wal`/`-shm` sidecars too).
    static func migrateDatabaseIfNeeded(
        from legacy: URL,
        to target: URL,
        fileManager: FileManager = .default
    ) {
        guard !fileManager.fileExists(atPath: target.path),
              fileManager.fileExists(atPath: legacy.path)
        else { return }
        try? fileManager.moveItem(at: legacy, to: target)
        for suffix in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacy.path + suffix)
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.moveItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
    }

    private static func appSupport(_ fileManager: FileManager) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw StoreError.openFailed("no Application Support directory") }
        return support.appendingPathComponent("com.proteles.ProtelesApp", isDirectory: true)
    }

    // MARK: - Schema

    private static func ensureSchema(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            // Base tables — MUSHclient v11 shape. IF NOT EXISTS so an
            // imported MUSHclient DB is left untouched and a fresh DB gets
            // a fully read-compatible schema.
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS areas (
              uid TEXT NOT NULL, name TEXT, texture TEXT, color TEXT,
              flags TEXT NOT NULL DEFAULT '', PRIMARY KEY(uid));
            CREATE TABLE IF NOT EXISTS rooms (
              uid TEXT NOT NULL, name TEXT, area TEXT, building TEXT, terrain TEXT,
              info TEXT, notes TEXT, x INTEGER, y INTEGER, z INTEGER,
              noportal INTEGER, norecall INTEGER,
              ignore_exits_mismatch INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(uid));
            CREATE TABLE IF NOT EXISTS exits (
              dir TEXT NOT NULL, fromuid TEXT NOT NULL, touid TEXT NOT NULL,
              level STRING NOT NULL DEFAULT '0', PRIMARY KEY(fromuid, dir));
            CREATE TABLE IF NOT EXISTS bookmarks (uid TEXT NOT NULL, notes TEXT, PRIMARY KEY(uid));
            CREATE TABLE IF NOT EXISTS environments (
              uid TEXT NOT NULL, name TEXT, color INTEGER, PRIMARY KEY(uid));
            CREATE TABLE IF NOT EXISTS terrain (
              name TEXT NOT NULL, color INTEGER, PRIMARY KEY(name));
            CREATE TABLE IF NOT EXISTS storage (name TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(name));
            CREATE INDEX IF NOT EXISTS rooms_area_index ON rooms (area);
            CREATE INDEX IF NOT EXISTS rooms_name_index ON rooms (name);
            CREATE INDEX IF NOT EXISTS exits_touid_index ON exits (touid);
            """)

            // Defensive column adds for older imported DBs (a v2–v9 `rooms`
            // table predates these flag columns).
            try addColumnIfMissing(db, table: "rooms", column: "noportal", decl: "INTEGER")
            try addColumnIfMissing(db, table: "rooms", column: "norecall", decl: "INTEGER")
            try addColumnIfMissing(
                db,
                table: "rooms",
                column: "ignore_exits_mismatch",
                decl: "INTEGER NOT NULL DEFAULT 0"
            )

            // Proteles extensions (additive — never break a SELECT-by-name).
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS proteles_meta (key TEXT NOT NULL, value TEXT, PRIMARY KEY(key));
            CREATE TABLE IF NOT EXISTS room_user_data (
              uid TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY(uid, key));
            """)
            try addColumnIfMissing(db, table: "exits", column: "weight", decl: "INTEGER")
            try addColumnIfMissing(db, table: "exits", column: "door", decl: "INTEGER")

            try db.execute(
                sql: "INSERT OR REPLACE INTO proteles_meta(key, value) VALUES('schema_version', ?)",
                arguments: [String(protelesSchemaVersion)]
            )
        }
    }

    private static func addColumnIfMissing(
        _ db: Database, table: String, column: String, decl: String
    ) throws {
        let existing = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            .compactMap { $0["name"] as String? }
        if !existing.contains(column) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(decl)")
        }
    }

    // MARK: - Writes

    /// Insert/replace a room (note is persisted separately via ``setNote``).
    public func upsert(_ room: Room) throws {
        try write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO rooms
                  (uid, name, area, building, terrain, info, x, y, z,
                   noportal, norecall, ignore_exits_mismatch)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    room.uid, room.name, room.area, room.building, room.terrain, room.info,
                    room.x, room.y, room.z,
                    room.noportal ? 1 : 0, room.norecall ? 1 : 0, room.ignoreExitsMismatch ? 1 : 0
                ]
            )
        }
    }

    /// Replace all exits leaving `uid` with `exits` (mirrors the mapper's
    /// `save_room_exits`: delete-then-insert keyed by `(fromuid, dir)`).
    public func saveExits(from uid: String, exits: [String: Exit]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM exits WHERE fromuid = ?", arguments: [uid])
            for exit in exits.values {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO exits (dir, fromuid, touid, level, weight, door)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [exit.dir, uid, exit.to, String(exit.level), exit.weight, exit.door?.rawValue]
                )
            }
        }
    }

    public func upsert(_ area: Area) throws {
        try write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO areas (uid, name, texture, color, flags) VALUES (?, ?, ?, ?, ?)",
                arguments: [area.uid, area.name, area.texture, area.color, area.flags]
            )
        }
    }

    /// One terrain environment row (code → name/colour).
    public struct Environment: Sendable, Equatable {
        public var uid: String
        public var name: String?
        public var color: Int?

        public init(uid: String, name: String?, color: Int?) {
            self.uid = uid
            self.name = name
            self.color = color
        }
    }

    /// Replace the whole `environments` table, mirroring the mapper's
    /// `update_gmcp_sectors`.
    public func replaceEnvironments(_ environments: [Environment]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM environments")
            for env in environments {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO environments (uid, name, color) VALUES (?, ?, ?)",
                    arguments: [env.uid, env.name, env.color]
                )
            }
        }
    }

    /// Set or clear a room's note (the `bookmarks` table).
    public func setNote(_ note: String?, uid: String) throws {
        try write { db in
            if let note, !note.isEmpty {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO bookmarks (uid, notes) VALUES (?, ?)",
                    arguments: [uid, note]
                )
            } else {
                try db.execute(sql: "DELETE FROM bookmarks WHERE uid = ?", arguments: [uid])
            }
        }
    }

    // MARK: - Metadata (proteles_meta key/value)

    /// Read a Proteles metadata value (e.g. a persisted UI preference).
    public func meta(forKey key: String) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT value FROM proteles_meta WHERE key = ?", arguments: [key])
        }
    }

    /// Write a Proteles metadata value.
    public func setMeta(_ value: String, forKey key: String) throws {
        try write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO proteles_meta (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Import

    /// What an incremental import added.
    public struct ImportSummary: Sendable, Equatable {
        public var rooms = 0
        public var areas = 0
        public var exits = 0
        public var notes = 0

        public var total: Int {
            rooms + areas + exits + notes
        }

        public var isEmpty: Bool {
            total == 0
        }
    }

    public enum ImportError: Error, Equatable {
        /// The chosen file isn't a recognisable mapper database.
        case notAMapperDatabase
    }

    /// Incrementally merge another mapper database into this one
    /// (`INSERT OR IGNORE` per table, keyed by primary key) — it *adds what
    /// we don't already have* and never overwrites local rooms, exits, or
    /// notes. Works against any MUSHclient-schema `Aardwolf.db`. Returns the
    /// per-table counts of newly inserted rows.
    public func importIncremental(from source: URL) throws -> ImportSummary {
        do {
            return try dbQueue.write { db in
                try Self.merge(into: db, from: source)
            }
        } catch let error as ImportError {
            throw error // surface our own errors unwrapped
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private static func merge(into db: Database, from source: URL) throws -> ImportSummary {
        try db.execute(sql: "ATTACH DATABASE ? AS importsrc", arguments: [source.path])
        defer { try? db.execute(sql: "DETACH DATABASE importsrc") }

        // Validate: a mapper DB has at least a `rooms` table.
        let hasRooms = try Bool.fetchOne(
            db,
            sql: """
            SELECT count(*) > 0 FROM importsrc.sqlite_master
            WHERE type = 'table' AND name = 'rooms'
            """
        ) ?? false
        guard hasRooms else { throw ImportError.notAMapperDatabase }

        var summary = ImportSummary()
        let roomColumns = """
        uid, name, area, building, terrain, info, x, y, z, \
        norecall, noportal, ignore_exits_mismatch
        """
        summary.rooms = try insertIgnore(db, table: "rooms", columns: roomColumns)
        summary.areas = try insertIgnore(db, table: "areas", columns: "uid, name, texture, color, flags")
        summary.exits = try insertIgnore(db, table: "exits", columns: "dir, fromuid, touid, level")
        summary.notes = try insertIgnore(db, table: "bookmarks", columns: "uid, notes")
        return summary
    }

    /// `INSERT OR IGNORE INTO <table> (cols) SELECT cols FROM importsrc.<table>`,
    /// returning the number of rows actually inserted. Tables missing from the
    /// source contribute zero (older DBs may lack `areas`/`bookmarks`).
    private static func insertIgnore(_ db: Database, table: String, columns: String) throws -> Int {
        let present = try Bool.fetchOne(
            db,
            sql: "SELECT count(*) > 0 FROM importsrc.sqlite_master WHERE type='table' AND name=?",
            arguments: [table]
        ) ?? false
        guard present else { return 0 }
        try db.execute(sql: """
        INSERT OR IGNORE INTO \(table) (\(columns))
        SELECT \(columns) FROM importsrc.\(table)
        """)
        return db.changesCount
    }

    // MARK: - Reads

    /// Fetch one room (with its exits and joined note), or nil if unknown.
    public func room(uid: String) throws -> Room? {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM rooms WHERE uid = ?", arguments: [uid])
            else { return nil }
            var room = Self.room(from: row)
            room.notes = try String.fetchOne(
                db, sql: "SELECT notes FROM bookmarks WHERE uid = ?", arguments: [uid]
            )
            let exitRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM exits WHERE fromuid = ?",
                arguments: [uid]
            )
            room.exits = Self.exits(from: exitRows)
            return room
        }
    }

    /// Load the entire graph (rooms + exits + areas + notes) into memory.
    /// Designed for the live DB scale (~30k rooms / ~93k exits): a handful
    /// of full-table scans, assembled in Swift.
    public func loadGraph() throws -> RoomGraph {
        try read { db in
            var rooms: [String: Room] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM rooms") {
                let room = Self.room(from: row)
                rooms[room.uid] = room
            }
            for row in try Row.fetchAll(db, sql: "SELECT uid, notes FROM bookmarks") {
                if let uid = row["uid"] as String? { rooms[uid]?.notes = row["notes"] as String? }
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM exits") {
                guard let from = row["fromuid"] as String? else { continue }
                let exit = Self.exit(from: row)
                rooms[from, default: Room(uid: from)].exits[exit.dir] = exit
            }
            var areas: [String: Area] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT uid, name, texture, color, flags FROM areas") {
                guard let uid = row["uid"] as String? else { continue }
                areas[uid] = Area(
                    uid: uid,
                    name: row["name"],
                    color: row["color"],
                    texture: row["texture"],
                    flags: row["flags"] ?? ""
                )
            }
            return RoomGraph(rooms: rooms, areas: areas)
        }
    }

    // MARK: - Row decoding

    private static func room(from row: Row) -> Room {
        Room(
            uid: row["uid"] ?? "",
            name: row["name"] ?? "",
            area: row["area"],
            building: row["building"],
            terrain: row["terrain"],
            info: row["info"],
            x: row["x"],
            y: row["y"],
            z: row["z"],
            noportal: (row["noportal"] as Int?) ?? 0 != 0,
            norecall: (row["norecall"] as Int?) ?? 0 != 0,
            ignoreExitsMismatch: (row["ignore_exits_mismatch"] as Int?) ?? 0 != 0
        )
    }

    private static func exit(from row: Row) -> Exit {
        // `exits.level` is declared STRING (NUMERIC affinity) so it may be
        // stored as an integer (179) or, in some DBs, as text ("179").
        // Decode tolerantly across storage classes.
        let levelValue = row["level"] as DatabaseValue
        let level = Int.fromDatabaseValue(levelValue)
            ?? String.fromDatabaseValue(levelValue).flatMap { Int($0) }
            ?? 0
        return Exit(
            dir: row["dir"] ?? "",
            to: row["touid"] ?? "",
            level: level,
            weight: row["weight"],
            door: (row["door"] as Int?).flatMap(Exit.Door.init(rawValue:))
        )
    }

    private static func exits(from rows: [Row]) -> [String: Exit] {
        var result: [String: Exit] = [:]
        for row in rows {
            let exit = exit(from: row)
            result[exit.dir] = exit
        }
        return result
    }

    // MARK: - GRDB helpers

    private func write<T>(_ block: (Database) throws -> T) throws -> T {
        do { return try dbQueue.write(block) } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private func read<T>(_ block: (Database) throws -> T) throws -> T {
        do { return try dbQueue.read(block) } catch { throw StoreError.readFailed(error.localizedDescription)
        }
    }
}

import GRDB

extension MapperStore {
    /// The reference Aardwolf mapper keeps an FTS3 `rooms_lookup(uid, name)`
    /// mirror in sync with `rooms`, and `mapper find` queries that table.
    /// Maintain it for MUSHclient DB compatibility and direct plugin readers.
    static func ensureRoomsLookup(_ db: Database) throws {
        try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS rooms_lookup USING FTS3(uid, name)")
    }

    /// Repair imported or older DBs whose FTS mirror predates Proteles' upkeep.
    static func repairRoomsLookupIfNeeded(_ db: Database) throws {
        let stale = try Bool.fetchOne(db, sql: """
        SELECT EXISTS (
          SELECT uid, coalesce(name, '') FROM rooms
          EXCEPT
          SELECT uid, coalesce(name, '') FROM rooms_lookup
        )
        OR EXISTS (
          SELECT uid, coalesce(name, '') FROM rooms_lookup
          EXCEPT
          SELECT uid, coalesce(name, '') FROM rooms
        )
        """) ?? false
        if stale { try rebuildRoomsLookup(db) }
    }

    static func rebuildRoomsLookup(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM rooms_lookup")
        try db.execute(sql: "INSERT INTO rooms_lookup (uid, name) SELECT uid, name FROM rooms")
    }

    static func syncRoomsLookup(_ db: Database, uid: String, name: String) throws {
        try db.execute(sql: "DELETE FROM rooms_lookup WHERE uid = ?", arguments: [uid])
        try db.execute(sql: "INSERT INTO rooms_lookup (uid, name) VALUES (?, ?)", arguments: [uid, name])
    }
}

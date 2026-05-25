import Foundation
import GRDB

/// Portal / recall / purge persistence for the mapper, faithful to
/// `aard_GMCP_mapper`'s schema use. Portals live in the `exits` table as rows
/// with `fromuid = '*'` (portal) or `'**'` (recall): `dir` is the command typed
/// to use it, `touid` the destination room, `level` the minimum level. Purges
/// also clean the `rooms_lookup` FTS *when present* (an imported Aardwolf.db
/// has it; our freshly-created DB does not).
public extension MapperStore {
    /// One portal/recall entry, joined to its destination room for display.
    struct PortalEntry: Sendable, Equatable {
        public let fromuid: String // "*" portal, "**" recall
        public let dir: String // command to use it
        public let touid: String
        public let level: Int
        public let roomName: String?
        public let area: String?
        public var isRecall: Bool {
            fromuid == "**"
        }
    }

    /// Portals + recalls, optionally filtered by destination area (LIKE), in the
    /// reference's order (area, then destination uid).
    func portals(areaFilter: String? = nil) throws -> [PortalEntry] {
        try read { db in
            let like = areaFilter.map { "%\($0)%" } ?? "%"
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT e.fromuid, e.dir, e.touid, e.level, r.name AS name, r.area AS area
                FROM exits e LEFT OUTER JOIN rooms r ON r.uid = e.touid
                WHERE e.fromuid IN ('*','**') AND IFNULL(r.area,'') LIKE ?
                ORDER BY r.area, e.touid
                """,
                arguments: [like]
            )
            return rows.map {
                PortalEntry(
                    fromuid: $0["fromuid"] ?? "*",
                    dir: $0["dir"] ?? "",
                    touid: $0["touid"] ?? "",
                    // level is STRING in an imported Aardwolf.db but may store as
                    // an integer here — read it tolerantly.
                    level: $0["level"] as Int? ?? 0,
                    roomName: $0["name"],
                    area: $0["area"]
                )
            }
        }
    }

    /// Add (or replace) a portal. `recall` (or a "home"/"recall" keyword)
    /// stores it as a recall (`fromuid = '**'`). Ensures the sentinel pseudo-
    /// rooms exist, mirroring the reference.
    func addPortal(dir: String, touid: String, level: Int, recall: Bool) throws {
        let from = recall ? "**" : "*"
        try write { db in
            try db.execute(sql: """
            INSERT OR REPLACE INTO rooms (uid, name, area) VALUES ('*','___HERE___','___EVERYWHERE___')
            """)
            if recall {
                try db.execute(sql: """
                INSERT OR REPLACE INTO rooms (uid, name, area) VALUES ('**','___HERE___','___EVERYWHERE___')
                """)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO exits (dir, fromuid, touid, level) VALUES (?, ?, ?, ?)",
                arguments: [dir, from, touid, String(level)]
            )
        }
    }

    /// Delete a portal/recall by its `dir` (the use-command).
    @discardableResult
    func deletePortal(dir: String) throws -> Bool {
        try write { db in
            try db.execute(
                sql: "DELETE FROM exits WHERE fromuid IN ('*','**') AND dir = ?",
                arguments: [dir]
            )
            return db.changesCount > 0
        }
    }

    /// Rename a portal's use-command.
    @discardableResult
    func changePortal(from oldDir: String, to newDir: String) throws -> Bool {
        try write { db in
            try db.execute(
                sql: "UPDATE exits SET dir = ? WHERE fromuid IN ('*','**') AND dir = ?",
                arguments: [newDir, oldDir]
            )
            return db.changesCount > 0
        }
    }

    /// Set a portal's level lock.
    @discardableResult
    func setPortalLevel(dir: String, level: Int) throws -> Bool {
        try write { db in
            try db.execute(
                sql: "UPDATE exits SET level = ? WHERE fromuid IN ('*','**') AND dir = ?",
                arguments: [String(max(0, level)), dir]
            )
            return db.changesCount > 0
        }
    }

    /// Remove every portal + recall.
    func purgePortals() throws {
        try write { db in try db.execute(sql: "DELETE FROM exits WHERE fromuid IN ('*','**')") }
    }

    /// Toggle a portal's recall flag by moving its row between `fromuid='*'`
    /// and `'**'` (reference `map_portal_recall`). Returns the new recall state,
    /// or nil if no such portal.
    func setPortalRecall(dir: String) throws -> Bool? {
        try write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT fromuid, touid, level FROM exits WHERE fromuid IN ('*','**') AND dir = ?",
                arguments: [dir]
            ) else { return nil }
            let wasRecall = (row["fromuid"] as String? ?? "*") == "**"
            let newFrom = wasRecall ? "*" : "**"
            if !wasRecall {
                try db.execute(sql: """
                INSERT OR REPLACE INTO rooms (uid, name, area) VALUES ('**','___HERE___','___EVERYWHERE___')
                """)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO exits (dir, fromuid, touid, level) VALUES (?, ?, ?, ?)",
                arguments: [dir, newFrom, row["touid"] as String? ?? "", String(row["level"] as Int? ?? 0)]
            )
            try db.execute(
                sql: "DELETE FROM exits WHERE dir = ? AND fromuid = ?",
                arguments: [dir, wasRecall ? "**" : "*"]
            )
            return !wasRecall
        }
    }

    /// Set the level lock on a specific room's exit (reference `lockexit`).
    @discardableResult
    func setExitLevel(from uid: String, dir: String, level: Int) throws -> Bool {
        try write { db in
            try db.execute(
                sql: "UPDATE exits SET level = ? WHERE dir = ? AND fromuid = ?",
                arguments: [String(max(0, level)), dir, uid]
            )
            return db.changesCount > 0
        }
    }

    // MARK: - Custom exits (cexits)

    /// Aardwolf's six cardinal directions; a "custom exit" is any exit from a
    /// real room whose direction isn't one of these (e.g. "enter portal").
    static let cardinalDirections = "('n','s','e','w','u','d')"

    /// One custom exit, joined to its source room for display.
    struct CustomExitEntry: Sendable, Equatable {
        public let fromuid: String
        public let dir: String
        public let touid: String
        public let roomName: String?
        public let area: String?
    }

    /// Custom exits, optionally filtered by the source room's area (LIKE).
    func customExits(areaFilter: String? = nil) throws -> [CustomExitEntry] {
        try read { db in
            let like = areaFilter.map { "%\($0)%" } ?? "%"
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT e.fromuid, e.dir, e.touid, r.name AS name, r.area AS area
                FROM exits e JOIN rooms r ON r.uid = e.fromuid
                WHERE e.dir NOT IN \(Self.cardinalDirections)
                  AND e.fromuid NOT IN ('*','**') AND IFNULL(r.area,'') LIKE ?
                ORDER BY r.area, e.fromuid
                """,
                arguments: [like]
            )
            return rows.map {
                CustomExitEntry(
                    fromuid: $0["fromuid"] ?? "",
                    dir: $0["dir"] ?? "",
                    touid: $0["touid"] ?? "",
                    roomName: $0["name"],
                    area: $0["area"]
                )
            }
        }
    }

    /// Add (or replace) a custom exit from one room to another.
    func addCustomExit(dir: String, from: String, to: String, level: Int) throws {
        try write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO exits (dir, fromuid, touid, level) VALUES (?, ?, ?, ?)",
                arguments: [dir, from, to, String(level)]
            )
        }
    }

    /// Delete all custom (non-cardinal) exits from a room.
    @discardableResult
    func deleteCustomExits(from uid: String) throws -> Int {
        try write { db in
            try db.execute(
                sql: "DELETE FROM exits WHERE fromuid = ? AND dir NOT IN \(Self.cardinalDirections)",
                arguments: [uid]
            )
            return db.changesCount
        }
    }

    /// Delete exits between two specific rooms (either direction of the pair).
    @discardableResult
    func deleteExits(from: String, to: String) throws -> Int {
        try write { db in
            try db.execute(
                sql: "DELETE FROM exits WHERE fromuid = ? AND touid = ?",
                arguments: [from, to]
            )
            return db.changesCount
        }
    }

    /// Purge custom exits — all of them, or scoped to one area's rooms.
    func purgeCustomExits(area: String?) throws {
        try write { db in
            if let area {
                try db.execute(
                    sql: """
                    DELETE FROM exits WHERE dir NOT IN \(Self.cardinalDirections) AND fromuid IN (
                      SELECT uid FROM rooms WHERE area = ?
                    )
                    """,
                    arguments: [area]
                )
            } else {
                try db.execute(
                    sql: """
                    DELETE FROM exits WHERE dir NOT IN \(Self.cardinalDirections)
                      AND fromuid NOT IN ('*','**')
                    """
                )
            }
        }
    }

    // MARK: - Purge / maintenance

    /// Delete a single room and everything referencing it (exits in/out, its
    /// bookmark, and its FTS row when present).
    func purgeRoom(uid: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM exits WHERE touid = ?", arguments: [uid])
            try db.execute(sql: "DELETE FROM exits WHERE fromuid = ?", arguments: [uid])
            try db.execute(sql: "DELETE FROM bookmarks WHERE uid = ?", arguments: [uid])
            if try Self.tableExists(db, "rooms_lookup") {
                try db.execute(sql: "DELETE FROM rooms_lookup WHERE uid = ?", arguments: [uid])
            }
            try db.execute(sql: "DELETE FROM rooms WHERE uid = ?", arguments: [uid])
        }
    }

    /// Delete an entire area: its rooms, their exits (both directions), their
    /// bookmarks/FTS rows, and the area row itself.
    func purgeZone(area: String) throws {
        try write { db in
            let inArea = "SELECT uid FROM rooms WHERE area = ?"
            try db.execute(sql: "DELETE FROM exits WHERE touid IN (\(inArea))", arguments: [area])
            try db.execute(sql: "DELETE FROM exits WHERE fromuid IN (\(inArea))", arguments: [area])
            try db.execute(sql: "DELETE FROM bookmarks WHERE uid IN (\(inArea))", arguments: [area])
            if try Self.tableExists(db, "rooms_lookup") {
                try db.execute(
                    sql: "DELETE FROM rooms_lookup WHERE uid IN (\(inArea))", arguments: [area]
                )
            }
            try db.execute(sql: "DELETE FROM rooms WHERE area = ?", arguments: [area])
            try db.execute(sql: "DELETE FROM areas WHERE uid = ?", arguments: [area])
        }
    }
}

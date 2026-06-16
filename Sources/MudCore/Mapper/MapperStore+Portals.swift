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
        // Portal rows live in the per-character overlay (D-111); their
        // destination room name/area come from the shared map. Fetch the rows,
        // then resolve names via the shared `rooms` (a Swift join — the two
        // tables can be in different files), and apply the area filter here.
        let rows = try personalRead { db in
            try Row.fetchAll(
                db,
                sql: "SELECT fromuid, dir, touid, level FROM exits WHERE fromuid IN ('*','**')"
            )
        }
        let names = try roomNamesAndAreas(for: rows.compactMap { $0["touid"] as String? })
        let filter = areaFilter?.lowercased()
        return rows.compactMap { row -> PortalEntry? in
            let touid = row["touid"] as String? ?? ""
            let meta = names[touid]
            if let filter, !(meta?.area?.lowercased().contains(filter) ?? filter.isEmpty) { return nil }
            return PortalEntry(
                fromuid: row["fromuid"] ?? "*",
                dir: row["dir"] ?? "",
                touid: touid,
                level: Self.levelInt(row, "level"),
                roomName: meta?.name,
                area: meta?.area
            )
        }
        .sorted { ($0.area ?? "", $0.touid) < ($1.area ?? "", $1.touid) }
    }

    /// Resolve destination room display name + area from the **shared** map for
    /// a set of uids (the Swift side of the cross-file join used by ``portals``
    /// / ``customExits``). Returns a uid → (name, area) lookup.
    private func roomNamesAndAreas(for uids: [String]) throws -> [String: (name: String?, area: String?)] {
        guard !uids.isEmpty else { return [:] }
        return try read { db in
            var out: [String: (name: String?, area: String?)] = [:]
            let unique = Array(Set(uids))
            for chunk in stride(from: 0, to: unique.count, by: 900).map({ Array(unique[$0..<min(
                $0 + 900,
                unique.count
            )]) }) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT uid, name, area FROM rooms WHERE uid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                for row in rows where row["uid"] != nil {
                    out[row["uid"]] = (row["name"], row["area"])
                }
            }
            return out
        }
    }

    /// Add (or replace) a portal. `recall` (or a "home"/"recall" keyword)
    /// stores it as a recall (`fromuid = '**'`). Ensures the sentinel pseudo-
    /// rooms exist, mirroring the reference.
    func addPortal(dir: String, touid: String, level: Int, recall: Bool) throws {
        let from = recall ? "**" : "*"
        // The `*`/`**` sentinel rooms are shared map scaffolding; the portal
        // exit itself is per-character → overlay (D-111).
        try ensurePortalSentinels(recall: recall)
        try personalWrite { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO exits (dir, fromuid, touid, level) VALUES (?, ?, ?, ?)",
                arguments: [dir, from, touid, String(level)]
            )
        }
    }

    /// Ensure the `*` (and, for recall, `**`) sentinel rooms exist in the
    /// shared map — the "from-anywhere" pseudo-rooms portal exits hang off.
    private func ensurePortalSentinels(recall: Bool) throws {
        try write { db in
            try db.execute(sql: """
            INSERT OR REPLACE INTO rooms (uid, name, area) VALUES ('*','___HERE___','___EVERYWHERE___')
            """)
            if recall {
                try db.execute(sql: """
                INSERT OR REPLACE INTO rooms (uid, name, area) VALUES ('**','___HERE___','___EVERYWHERE___')
                """)
            }
        }
    }

    /// Delete a portal/recall by its `dir` (the use-command).
    @discardableResult
    func deletePortal(dir: String) throws -> Bool {
        try personalWrite { db in
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
        try personalWrite { db in
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
        try personalWrite { db in
            try db.execute(
                sql: "UPDATE exits SET level = ? WHERE fromuid IN ('*','**') AND dir = ?",
                arguments: [String(max(0, level)), dir]
            )
            return db.changesCount > 0
        }
    }

    /// Remove every portal + recall.
    func purgePortals() throws {
        try personalWrite { db in try db.execute(sql: "DELETE FROM exits WHERE fromuid IN ('*','**')") }
    }

    /// Toggle a portal's recall flag by moving its row between `fromuid='*'`
    /// and `'**'` (reference `map_portal_recall`). Returns the new recall state,
    /// or nil if no such portal.
    func setPortalRecall(dir: String) throws -> Bool? {
        let newRecall: Bool? = try personalWrite { db -> Bool? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT fromuid, touid, level FROM exits WHERE fromuid IN ('*','**') AND dir = ?",
                arguments: [dir]
            ) else { return nil }
            let wasRecall = (row["fromuid"] as String? ?? "*") == "**"
            try db.execute(
                sql: "INSERT OR REPLACE INTO exits (dir, fromuid, touid, level) VALUES (?, ?, ?, ?)",
                arguments: [
                    dir,
                    wasRecall ? "*" : "**",
                    row["touid"] as String? ?? "",
                    String(Self.levelInt(row, "level"))
                ]
            )
            try db.execute(
                sql: "DELETE FROM exits WHERE dir = ? AND fromuid = ?",
                arguments: [dir, wasRecall ? "**" : "*"]
            )
            return !wasRecall
        }
        // The `**` sentinel lives in the shared map; ensure it when a portal
        // becomes a recall.
        if newRecall == true { try? ensurePortalSentinels(recall: true) }
        return newRecall
    }

    /// Set the level lock on a specific room's exit (reference `lockexit`).
    /// With an overlay attached (D-111), a lock on a *shared cardinal* exit is
    /// recorded in the overlay's `exit_locks` (the shared row is never mutated);
    /// a lock on a per-character portal/custom exit updates that overlay `exits`
    /// row. In single-file mode the level stays on the `exits` row, exactly as
    /// before the split.
    @discardableResult
    func setExitLevel(from uid: String, dir: String, level: Int) throws -> Bool {
        let value = String(max(0, level))
        if hasPersonalStore, Self.isCardinal(dir), uid != "*", uid != "**" {
            try personalWrite { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO exit_locks (fromuid, dir, level) VALUES (?, ?, ?)",
                    arguments: [uid, dir, value]
                )
            }
            return true
        }
        return try personalWrite { db in
            try db.execute(
                sql: "UPDATE exits SET level = ? WHERE dir = ? AND fromuid = ?",
                arguments: [value, dir, uid]
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

    /// Custom exits, optionally filtered by the source room's area. Rows live in
    /// the per-character overlay (D-111); the source room name/area come from the
    /// shared map via a Swift join (the original's `JOIN rooms` was an inner join,
    /// so unknown source rooms are excluded here too).
    func customExits(areaFilter: String? = nil) throws -> [CustomExitEntry] {
        let rows = try personalRead { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT fromuid, dir, touid FROM exits
                WHERE dir NOT IN \(Self.cardinalDirections) AND fromuid NOT IN ('*','**')
                """
            )
        }
        let names = try roomNamesAndAreas(for: rows.compactMap { $0["fromuid"] as String? })
        let filter = areaFilter?.lowercased()
        return rows.compactMap { row -> CustomExitEntry? in
            let from = row["fromuid"] as String? ?? ""
            guard let meta = names[from] else { return nil } // inner join
            if let filter, !(meta.area?.lowercased().contains(filter) ?? filter.isEmpty) { return nil }
            return CustomExitEntry(
                fromuid: from,
                dir: row["dir"] ?? "",
                touid: row["touid"] ?? "",
                roomName: meta.name,
                area: meta.area
            )
        }
        .sorted { ($0.area ?? "", $0.fromuid) < ($1.area ?? "", $1.fromuid) }
    }

    /// Add (or replace) a custom exit from one room to another.
    func addCustomExit(dir: String, from: String, to: String, level: Int) throws {
        try personalWrite { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO exits (dir, fromuid, touid, level) VALUES (?, ?, ?, ?)",
                arguments: [dir, from, to, String(level)]
            )
        }
    }

    /// Delete all custom (non-cardinal) exits from a room.
    @discardableResult
    func deleteCustomExits(from uid: String) throws -> Int {
        try personalWrite { db in
            try db.execute(
                sql: "DELETE FROM exits WHERE fromuid = ? AND dir NOT IN \(Self.cardinalDirections)",
                arguments: [uid]
            )
            return db.changesCount
        }
    }

    /// Delete exits between two specific rooms (either direction of the pair) —
    /// from both the shared map (cardinals) and the overlay (portals/customs).
    @discardableResult
    func deleteExits(from: String, to: String) throws -> Int {
        var count = try write { db in
            try db.execute(
                sql: "DELETE FROM exits WHERE fromuid = ? AND touid = ?", arguments: [from, to]
            )
            return db.changesCount
        }
        if hasPersonalStore {
            count += try personalWrite { db in
                try db.execute(
                    sql: "DELETE FROM exits WHERE fromuid = ? AND touid = ?", arguments: [from, to]
                )
                return db.changesCount
            }
        }
        return count
    }

    /// Purge custom exits — all of them, or scoped to one area's rooms. Custom
    /// exits live in the overlay (D-111); for the area-scoped case the room uids
    /// come from the shared map (the overlay has no `rooms` table).
    func purgeCustomExits(area: String?) throws {
        guard let area else {
            try personalWrite { db in
                try db.execute(
                    sql: """
                    DELETE FROM exits WHERE dir NOT IN \(Self.cardinalDirections)
                      AND fromuid NOT IN ('*','**')
                    """
                )
            }
            return
        }
        let uids = try roomUIDs(inArea: area)
        guard !uids.isEmpty else { return }
        try personalWrite { db in
            try Self.forEachUIDChunk(uids) { placeholders, chunk in
                try db.execute(
                    sql: """
                    DELETE FROM exits WHERE dir NOT IN \(Self.cardinalDirections)
                      AND fromuid IN (\(placeholders))
                    """,
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    // MARK: - Purge / maintenance

    /// Delete a single room and everything referencing it — shared (exits in/out,
    /// bookmark, FTS, room) and, when attached, the overlay (its exits in/out,
    /// exit-locks, bookmark).
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
        guard hasPersonalStore else { return }
        try personalWrite { db in
            try db.execute(sql: "DELETE FROM exits WHERE touid = ?", arguments: [uid])
            try db.execute(sql: "DELETE FROM exits WHERE fromuid = ?", arguments: [uid])
            try db.execute(sql: "DELETE FROM exit_locks WHERE fromuid = ?", arguments: [uid])
            try db.execute(sql: "DELETE FROM bookmarks WHERE uid = ?", arguments: [uid])
        }
    }

    /// Delete an entire area: its rooms, their exits (both directions), their
    /// bookmarks/FTS rows, and the area row itself — plus the overlay's exits,
    /// exit-locks, and bookmarks for those rooms when attached.
    func purgeZone(area: String) throws {
        let uids = try roomUIDs(inArea: area) // capture before the shared rooms go
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
        guard hasPersonalStore, !uids.isEmpty else { return }
        try personalWrite { db in
            try Self.forEachUIDChunk(uids) { placeholders, chunk in
                try db.execute(
                    sql: "DELETE FROM exits WHERE touid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                try db.execute(
                    sql: "DELETE FROM exits WHERE fromuid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                try db.execute(
                    sql: "DELETE FROM exit_locks WHERE fromuid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                try db.execute(
                    sql: "DELETE FROM bookmarks WHERE uid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    /// Room uids in an area, read from the shared map.
    private func roomUIDs(inArea area: String) throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: "SELECT uid FROM rooms WHERE area = ?", arguments: [area])
        }
    }

    /// Run `body` over `uids` in ≤900-id chunks (under SQLite's parameter cap),
    /// passing the `?,?,…` placeholder string and the chunk for binding.
    private static func forEachUIDChunk(
        _ uids: [String], _ body: (String, [String]) throws -> Void
    ) throws {
        for start in stride(from: 0, to: uids.count, by: 900) {
            let chunk = Array(uids[start..<min(start + 900, uids.count)])
            try body(chunk.map { _ in "?" }.joined(separator: ","), chunk)
        }
    }
}

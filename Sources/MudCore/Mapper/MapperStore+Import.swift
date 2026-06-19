import Foundation
import GRDB

public extension MapperStore {
    struct EmptyScope: OptionSet, Sendable, Equatable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let shared = EmptyScope(rawValue: 1 << 0)
        public static let personal = EmptyScope(rawValue: 1 << 1)
        public static let all: EmptyScope = [.shared, .personal]
    }

    /// Incrementally merge another mapper database into this one
    /// (`INSERT OR IGNORE` per table, keyed by primary key). It adds rows we
    /// don't already have and never overwrites local rooms, exits, or notes.
    /// Split stores import shared world facts into the shared DB and
    /// per-character overlays into the personal DB.
    func importIncremental(from source: URL) throws -> ImportSummary {
        do {
            guard personalQueue != nil else {
                return try dbQueue.write { db in
                    try Self.mergeSingleStore(into: db, from: source)
                }
            }
            var summary = try dbQueue.write { db in
                try Self.mergeSharedTables(into: db, from: source)
            }
            let personal = try personalWrite { db in
                try Self.mergePersonalTables(into: db, from: source)
            }
            summary.exits += personal.exits
            summary.exitLocks += personal.exitLocks
            summary.notes += personal.notes
            return summary
        } catch let error as ImportError {
            throw error
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Delete selected map content while leaving schema and `proteles_meta`
    /// preferences intact. This is a development/testing affordance so a DB
    /// can be reset and re-imported.
    func empty(_ scope: EmptyScope = .all) throws {
        do {
            if scope.contains(.shared) {
                try dbQueue.write { db in
                    for table in [
                        "rooms", "exits", "areas", "bookmarks",
                        "environments", "terrain", "storage",
                        "room_user_data", "rooms_lookup"
                    ] {
                        try db.execute(sql: "DELETE FROM \(table)")
                    }
                }
            }
            if scope.contains(.personal), personalQueue != nil {
                try personalWrite { db in
                    for table in [
                        "exits", "exit_locks", "bookmarks",
                        "storage", "room_user_data"
                    ] {
                        try db.execute(sql: "DELETE FROM \(table)")
                    }
                }
            }
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}

private extension MapperStore {
    static func mergeSingleStore(into db: Database, from source: URL) throws -> ImportSummary {
        try db.execute(sql: "ATTACH DATABASE ? AS importsrc", arguments: [source.path])
        defer { try? db.execute(sql: "DETACH DATABASE importsrc") }
        try validateMapperDatabase(db)

        var summary = ImportSummary()
        summary.rooms = try insertIgnore(db, table: "rooms", columns: roomColumns)
        summary.areas = try insertIgnore(db, table: "areas", columns: areaColumns)
        summary.exits = try insertIgnore(db, table: "exits", columns: "dir, fromuid, touid, level")
        summary.notes = try insertIgnore(db, table: "bookmarks", columns: "uid, notes")
        summary.environments = try insertIgnore(db, table: "environments", columns: environmentColumns)
        try rebuildRoomsLookup(db)
        return summary
    }

    static func mergeSharedTables(into db: Database, from source: URL) throws -> ImportSummary {
        try db.execute(sql: "ATTACH DATABASE ? AS importsrc", arguments: [source.path])
        defer { try? db.execute(sql: "DETACH DATABASE importsrc") }
        try validateMapperDatabase(db)

        var summary = ImportSummary()
        summary.rooms = try insertIgnore(db, table: "rooms", columns: roomColumns)
        summary.areas = try insertIgnore(db, table: "areas", columns: areaColumns)
        summary.exits = try insertIgnore(
            db,
            table: "exits",
            columns: "dir, fromuid, touid, level",
            selectColumns: "dir, fromuid, touid, '0'",
            whereSQL: "fromuid NOT IN ('*','**') AND \(cardinalInClause)"
        )
        // The sector palette (terrain name->colour). Without this, imported
        // rooms have no colour and the whole map renders grey.
        summary.environments = try insertIgnore(db, table: "environments", columns: environmentColumns)
        try rebuildRoomsLookup(db)
        return summary
    }

    static func mergePersonalTables(into db: Database, from source: URL) throws -> ImportSummary {
        try db.execute(sql: "ATTACH DATABASE ? AS importsrc", arguments: [source.path])
        defer { try? db.execute(sql: "DETACH DATABASE importsrc") }
        try validateMapperDatabase(db)

        var summary = ImportSummary()
        summary.exits = try insertIgnore(
            db,
            table: "exits",
            columns: "dir, fromuid, touid, level",
            whereSQL: "fromuid IN ('*','**') OR NOT \(cardinalInClause)"
        )
        summary.exitLocks = try insertIgnore(
            db,
            table: "exit_locks",
            columns: "fromuid, dir, level",
            selectColumns: "fromuid, dir, level",
            sourceTable: "exits",
            whereSQL: "fromuid NOT IN ('*','**') AND \(cardinalInClause) AND level != '0'"
        )
        summary.notes = try insertIgnore(db, table: "bookmarks", columns: "uid, notes")
        return summary
    }

    static func validateMapperDatabase(_ db: Database) throws {
        let hasRooms = try Bool.fetchOne(
            db,
            sql: """
            SELECT count(*) > 0 FROM importsrc.sqlite_master
            WHERE type = 'table' AND name = 'rooms'
            """
        ) ?? false
        guard hasRooms else { throw ImportError.notAMapperDatabase }
    }

    /// `INSERT OR IGNORE INTO <table> (cols) SELECT cols FROM importsrc.<table>`,
    /// returning the number of rows actually inserted. Tables missing from the
    /// source contribute zero (older DBs may lack `areas`/`bookmarks`).
    static func insertIgnore(
        _ db: Database,
        table: String,
        columns: String,
        selectColumns: String? = nil,
        sourceTable: String? = nil,
        whereSQL: String? = nil
    ) throws -> Int {
        let sourceTable = sourceTable ?? table
        let present = try Bool.fetchOne(
            db,
            sql: "SELECT count(*) > 0 FROM importsrc.sqlite_master WHERE type='table' AND name=?",
            arguments: [sourceTable]
        ) ?? false
        guard present else { return 0 }

        let select = selectColumns ?? columns
        let filter = whereSQL.map { " WHERE \($0)" } ?? ""
        try db.execute(sql: """
        INSERT OR IGNORE INTO \(table) (\(columns))
        SELECT \(select) FROM importsrc.\(sourceTable)\(filter)
        """)
        return db.changesCount
    }

    static let roomColumns = """
    uid, name, area, building, terrain, info, x, y, z, \
    norecall, noportal, ignore_exits_mismatch
    """

    static let areaColumns = "uid, name, texture, color, flags"
    static let environmentColumns = "uid, name, color"
}

import GRDB

extension MapperStore {
    static func addColumnIfMissing(
        _ db: Database,
        table: String,
        column: String,
        decl: String
    ) throws {
        let existing = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            .compactMap { $0["name"] as String? }
        if !existing.contains(column) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(decl)")
        }
    }
}

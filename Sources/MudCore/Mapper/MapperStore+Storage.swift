import Foundation
import GRDB

/// The MUSHclient mapper `storage(name, data)` table — the reference mapper's
/// general key/value store. Proteles uses it for the bounce-portal/recall
/// designations so they survive a restart (mapper-fidelity D-90 follow-up).
public extension MapperStore {
    /// Read a `storage(name, data)` row.
    func storageValue(_ name: String) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT data FROM storage WHERE name = ?", arguments: [name])
        }
    }

    /// Write (insert-or-replace) a `storage(name, data)` row.
    func setStorage(_ name: String, _ data: String) throws {
        try write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO storage (name, data) VALUES (?, ?)",
                arguments: [name, data]
            )
        }
    }

    /// Delete a `storage` row.
    func deleteStorage(_ name: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM storage WHERE name = ?", arguments: [name])
        }
    }
}

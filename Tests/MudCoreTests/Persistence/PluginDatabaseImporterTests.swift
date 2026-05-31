import Foundation
import GRDB
@testable import MudCore
import Testing

/// File-level import/reset for the plugin-owned SQLite DBs (dinv, leveldb):
/// validate the source is a database, replace the target whole-file (clearing
/// stale WAL/SHM sidecars), and delete on reset.
@Suite("PluginDatabaseImporter")
struct PluginDatabaseImporterTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real (tiny) SQLite file with one table.
    private func makeSQLite(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE t (id INTEGER)") }
    }

    @Test("isSQLiteDatabase accepts a real DB and rejects other files")
    func detectsSQLite() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("real.db")
        try makeSQLite(at: db)
        let text = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)

        #expect(PluginDatabaseImporter.isSQLiteDatabase(db))
        #expect(!PluginDatabaseImporter.isSQLiteDatabase(text))
    }

    @Test("replace copies the source over the target and clears WAL/SHM sidecars")
    func replaceClearsSidecars() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("nested/state/dinv.db")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Pre-existing target + stale journal sidecars.
        try "OLD".write(to: target, atomically: true, encoding: .utf8)
        let wal = URL(fileURLWithPath: target.path + "-wal")
        let shm = URL(fileURLWithPath: target.path + "-shm")
        try "wal".write(to: wal, atomically: true, encoding: .utf8)
        try "shm".write(to: shm, atomically: true, encoding: .utf8)

        let source = dir.appendingPathComponent("import.db")
        try makeSQLite(at: source)

        try PluginDatabaseImporter.replace(target: target, with: source)

        #expect(PluginDatabaseImporter.isSQLiteDatabase(target), "target wasn't replaced by the DB")
        #expect(!FileManager.default.fileExists(atPath: wal.path), "stale -wal survived")
        #expect(!FileManager.default.fileExists(atPath: shm.path), "stale -shm survived")
    }

    @Test("replace creates intermediate directories")
    func replaceCreatesDirs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a/b/c/leveldb.db")
        let source = dir.appendingPathComponent("src.db")
        try makeSQLite(at: source)
        try PluginDatabaseImporter.replace(target: target, with: source)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("replace rejects a non-SQLite source")
    func replaceRejectsNonSQLite() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("t.db")
        let source = dir.appendingPathComponent("bogus.db")
        try "not a database".write(to: source, atomically: true, encoding: .utf8)
        #expect(throws: PluginDatabaseImporter.ImportError.notSQLite) {
            try PluginDatabaseImporter.replace(target: target, with: source)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path), "target created from a bad source")
    }

    @Test("delete removes the file + sidecars and is idempotent")
    func deleteRemovesAll() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("db.db")
        try makeSQLite(at: target)
        try "wal".write(to: URL(fileURLWithPath: target.path + "-wal"), atomically: true, encoding: .utf8)

        try PluginDatabaseImporter.delete(target: target)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: target.path + "-wal"))
        // Idempotent: deleting again is fine.
        try PluginDatabaseImporter.delete(target: target)
    }
}

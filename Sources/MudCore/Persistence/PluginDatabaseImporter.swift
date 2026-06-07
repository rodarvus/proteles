import Foundation

/// Import / reset for **plugin-owned** SQLite databases — dinv (inventory) and
/// leveldb (leveling history). Unlike the mapper (`MapperStore`) and
/// Search-and-Destroy (`SearchAndDestroyStore`), which are native GRDB stores we
/// can merge *incrementally* (we own the schema), these files are written and
/// migrated entirely by the vendored Lua plugins. We don't safely know how to
/// merge two of them without fighting the plugin's own migrations, so import is
/// a **whole-file replace** (the user brings over their existing DB) and reset
/// is a **delete** (the plugin recreates an empty one on next load/build).
///
/// Because the plugin holds the file open via lsqlite3 while loaded, callers
/// must do this **while disconnected** (plugins load at the in-game signal —
/// D-74 — so a disconnected session has the file closed). Replacing also clears
/// the WAL/SHM sidecars so the imported DB isn't shadowed by a stale journal.
public enum PluginDatabaseImporter {
    public enum ImportError: Error, Equatable {
        /// The chosen file isn't an SQLite database.
        case notSQLite
        /// No target path could be resolved (e.g. dinv hasn't created its DB yet).
        case noTarget(String)
    }

    /// SQLite's 16-byte file header (`"SQLite format 3\0"`).
    static func isSQLiteDatabase(_ url: URL, fileManager _: FileManager = .default) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16) else { return false }
        return head == Data("SQLite format 3\0".utf8)
    }

    /// Replace `target` with `source` (a validated SQLite file copy), removing
    /// the existing file + its `-wal`/`-shm` sidecars first so nothing stale
    /// shadows the import. Creates intermediate directories. Throws
    /// ``ImportError/notSQLite`` if `source` isn't a database.
    public static func replace(target: URL, with source: URL, fileManager: FileManager = .default) throws {
        guard isSQLiteDatabase(source, fileManager: fileManager) else { throw ImportError.notSQLite }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try delete(target: target, fileManager: fileManager)
        try fileManager.copyItem(at: source, to: target)
    }

    /// Delete `target` and its `-wal`/`-shm` sidecars. Idempotent (a missing
    /// file is not an error).
    public static func delete(target: URL, fileManager: FileManager = .default) throws {
        let files = [
            target,
            URL(fileURLWithPath: target.path + "-wal"),
            URL(fileURLWithPath: target.path + "-shm")
        ]
        for url in files where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Targets

    /// leveldb's per-character database, `Databases/<character>/leveldb.db`
    /// (flat, via `proteles.databaseDir()`, #44).
    public static func levelDBTarget(
        character: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try LevelDBStore.defaultURL(character: character, fileManager: fileManager)
    }

    /// The active character's dinv database, `Databases/<character>/dinv.db`
    /// (flat, via `proteles.databaseDir()`, #44). Returns `nil` if dinv hasn't
    /// created it yet (the caller asks the user to connect + `dinv build` once).
    public static func dinvTarget(character: String, fileManager: FileManager = .default) -> URL? {
        guard let url = try? ProtelesPaths.pluginDatabaseURL(
            character: character, fileName: "dinv.db", fileManager: fileManager
        ) else { return nil }
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}

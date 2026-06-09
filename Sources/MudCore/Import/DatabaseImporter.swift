import Foundation

/// Write phase (P2): copy selected MUSHclient databases to their Proteles
/// destinations. Mapper + S&D are global (`Databases/`); dinv/leveldb/plugin
/// databases are per-character (`Databases/<character>/`). A plain file copy
/// (overwriting) — sophisticated merge (S&D's incremental merge, mapper FTS) is
/// a later refinement tracked in the import open-questions issue.
public enum DatabaseImporter {
    /// The Proteles destination for an imported database, or nil to skip
    /// (`.unknown`). `character` is the target for per-character databases that
    /// don't carry their own (leveldb, plugin-owned); dinv uses its own character.
    public static func destination(
        for entry: ImportManifest.DatabaseEntry,
        character: String,
        in databasesDirectory: URL
    ) -> URL? {
        func perCharacter(_ char: String, _ file: String) -> URL {
            databasesDirectory
                .appendingPathComponent(char, isDirectory: true)
                .appendingPathComponent(file)
        }
        switch entry.kind {
        case .mapper: return databasesDirectory.appendingPathComponent("Aardwolf.db")
        case .searchAndDestroy: return databasesDirectory.appendingPathComponent("SnDdb.db")
        case .dinv: return perCharacter(entry.character ?? character, "dinv.db")
        case .leveldb: return perCharacter(character, "leveldb.db")
        case .pluginOwned: return perCharacter(character, entry.url.lastPathComponent)
        case .unknown: return nil
        }
    }

    public enum ImportError: Error, Equatable {
        case copyFailed(source: String, reason: String)
    }

    /// Copy one database to its destination (creating parent dirs, overwriting an
    /// existing file). Returns the destination, or nil if the entry is skipped.
    @discardableResult
    public static func copy(
        _ entry: ImportManifest.DatabaseEntry,
        character: String,
        in databasesDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let destination = destination(
            for: entry, character: character, in: databasesDirectory
        ) else { return nil }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: entry.url, to: destination)
            return destination
        } catch {
            throw ImportError.copyFailed(
                source: entry.url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
    }
}

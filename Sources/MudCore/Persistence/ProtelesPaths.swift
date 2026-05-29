import Foundation

/// The user-visible Proteles data home under `~/Documents/Proteles/`.
///
/// Unlike the opaque app-support container, this tree is somewhere the user can
/// navigate to in Finder, hand-edit, and (later) zip up to share with friends.
/// It holds the plugin library and the world-wide databases; `Scripts/` and
/// `Aliases/` will join it later (see `docs/plans/PLUGIN_LIBRARY_PLAN.md`).
///
/// ```
/// ~/Documents/Proteles/
///   Plugins/      one self-contained dir per added plugin
///   Databases/    global, world-wide DBs (mapper Aardwolf.db, S&D SnDdb.db)
/// ```
///
/// The app is not sandboxed, so `~/Documents` is freely writable. Each accessor
/// creates the directory on demand.
public enum ProtelesPaths {
    public enum PathError: Error, Equatable {
        case noDocumentsDirectory
    }

    /// `~/Documents/Proteles/` — the data home. Created if missing.
    public static func home(fileManager: FileManager = .default) throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw PathError.noDocumentsDirectory }
        return try ensure(documents.appendingPathComponent("Proteles", isDirectory: true), fileManager)
    }

    /// `~/Documents/Proteles/Plugins/` — one self-contained dir per plugin.
    public static func pluginsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("Plugins", isDirectory: true),
            fileManager
        )
    }

    /// `~/Documents/Proteles/Databases/` — global, world-wide databases (the
    /// mapper's `Aardwolf.db`, Search-and-Destroy's `SnDdb.db`). Used in Phase B.
    public static func databasesDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("Databases", isDirectory: true),
            fileManager
        )
    }

    /// `~/Documents/Proteles/Scripts/` — the user's triggers/aliases/timers/macros
    /// (split by kind, per-character or shared). Discoverable + hand-editable.
    public static func scriptsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("Scripts", isDirectory: true),
            fileManager
        )
    }

    /// The directory for one plugin, `Plugins/<dirName>/`. Created if missing.
    public static func pluginDirectory(
        named dirName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try ensure(
            pluginsDirectory(fileManager: fileManager).appendingPathComponent(dirName, isDirectory: true),
            fileManager
        )
    }

    /// A plugin's **per-character** data directory,
    /// `Plugins/<dirName>/data/<character>/` (created) — where its SQLite DB +
    /// saved state live (code is shared across characters; data is not).
    /// `character` is a readable, filesystem-safe key (the character name) so the
    /// path is navigable, not an opaque UUID.
    public static func pluginDataDirectory(
        named dirName: String,
        character: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try ensure(
            pluginDirectory(named: dirName, fileManager: fileManager)
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent(character, isDirectory: true),
            fileManager
        )
    }

    /// The global mapper database, `Databases/Aardwolf.db` — one map of Aardwolf
    /// shared across all characters.
    public static func mapperDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        try databasesDirectory(fileManager: fileManager).appendingPathComponent("Aardwolf.db")
    }

    /// The global Search-and-Destroy database, `Databases/SnDdb.db` — area/mob
    /// data shared across all characters.
    public static func searchAndDestroyDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        try databasesDirectory(fileManager: fileManager).appendingPathComponent("SnDdb.db")
    }

    /// A filesystem-safe, human-readable directory name for a plugin display
    /// name (kept readable for discoverability — spaces are fine on macOS;
    /// only path-hostile characters are replaced). Falls back to "Plugin".
    public static func directorySlug(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Plugin" }
        let hostile = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = String(trimmed.unicodeScalars.map { hostile.contains($0) ? "-" : Character($0) })
        return cleaned.isEmpty ? "Plugin" : cleaned
    }

    private static func ensure(_ url: URL, _ fileManager: FileManager) throws -> URL {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

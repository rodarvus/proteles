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

    // MARK: - Settings (config — issue #43)

    /// `~/Documents/Proteles/Settings/` — app preferences + world profiles +
    /// the installed-plugin registry. Hand-editable config (not transient UI
    /// state, which stays in `UserDefaults`).
    public static func settingsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("Settings", isDirectory: true),
            fileManager
        )
    }

    /// `Settings/worlds.json` — the world-profile collection (was the opaque
    /// App-Support `profiles.json`).
    public static func worldsFile(fileManager: FileManager = .default) throws -> URL {
        try settingsDirectory(fileManager: fileManager).appendingPathComponent("worlds.json")
    }

    /// `Settings/preferences.json` — the meaningful app preferences (Phase 2).
    public static func preferencesFile(fileManager: FileManager = .default) throws -> URL {
        try settingsDirectory(fileManager: fileManager).appendingPathComponent("preferences.json")
    }

    /// `Settings/plugin-library.json` — the installed-plugin registry + per-world
    /// enablement.
    public static func pluginLibraryFile(fileManager: FileManager = .default) throws -> URL {
        try settingsDirectory(fileManager: fileManager).appendingPathComponent("plugin-library.json")
    }

    // MARK: - State (mutable runtime state — issue #43)

    /// `~/Documents/Proteles/State/` — mutable runtime state: the resume
    /// breadcrumb, scrollback DB, plugin SaveState, per-world variables,
    /// diagnostics. Visible but not really hand-edited.
    public static func stateDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("State", isDirectory: true),
            fileManager
        )
    }

    /// `State/resume.json` — the session-resume breadcrumb (#42).
    public static func resumeFile(fileManager: FileManager = .default) throws -> URL {
        try stateDirectory(fileManager: fileManager).appendingPathComponent("resume.json")
    }

    /// `State/scrollback.sqlite` — the rendered-output history DB.
    public static func scrollbackFile(fileManager: FileManager = .default) throws -> URL {
        try stateDirectory(fileManager: fileManager).appendingPathComponent("scrollback.sqlite")
    }

    /// `State/variables/<world>.json` — per-world script variables.
    public static func variablesFile(
        world: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let dir = try ensure(
            stateDirectory(fileManager: fileManager).appendingPathComponent("variables", isDirectory: true),
            fileManager
        )
        return dir.appendingPathComponent("\(world).json")
    }

    /// `State/plugins/<plugin>-<character>.json` — a plugin's non-DB SaveState,
    /// labelled by plugin + character so it's obvious whose state it is.
    public static func pluginStateFile(
        plugin: String,
        character: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let dir = try ensure(
            stateDirectory(fileManager: fileManager).appendingPathComponent("plugins", isDirectory: true),
            fileManager
        )
        return dir.appendingPathComponent("\(plugin)-\(character).json")
    }

    /// `State/modules/<key>.json` — built-in module ("native plugin") state +
    /// enablement for one world (keyed by the stable world id; `worlds.json`
    /// maps id↔name).
    public static func moduleStateFile(
        key: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let dir = try ensure(
            stateDirectory(fileManager: fileManager).appendingPathComponent("modules", isDirectory: true),
            fileManager
        )
        return dir.appendingPathComponent("\(key).json")
    }

    /// `State/diagnostics/` — MetricKit crash/hang payloads (opt-in).
    public static func diagnosticsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            stateDirectory(fileManager: fileManager).appendingPathComponent("diagnostics", isDirectory: true),
            fileManager
        )
    }

    // MARK: - Recordings + logs (issue #43)

    /// `~/Documents/Proteles/Recordings/` — auto debug capture (`.jsonl` + `.log`).
    public static func recordingsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("Recordings", isDirectory: true),
            fileManager
        )
    }

    /// `~/Documents/Proteles/Logs/` — user-facing session logs (Logging pref).
    public static func logsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("Logs", isDirectory: true),
            fileManager
        )
    }

    /// `Databases/<character>/` — the per-character directory for plugin DBs
    /// (each plugin drops `<plugin>.db` here, flat — no plugin-chosen subdirs).
    /// Mapper + S&D stay at the `Databases/` root (global, shared). Surfaced to
    /// plugins as `proteles.databaseDir()`.
    public static func pluginDatabasesDirectory(
        character: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try ensure(
            databasesDirectory(fileManager: fileManager)
                .appendingPathComponent(character, isDirectory: true),
            fileManager
        )
    }

    /// `Databases/<character>/<fileName>` — a specific per-character plugin DB.
    public static func pluginDatabaseURL(
        character: String,
        fileName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try pluginDatabasesDirectory(character: character, fileManager: fileManager)
            .appendingPathComponent(fileName)
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

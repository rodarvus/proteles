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
    ///
    /// Under a test runner this redirects to a temp sandbox so tests never touch
    /// the user's real `~/Documents` (#45). Detection keys on signals present
    /// only when testing (the SwiftPM `swiftpm-testing-helper`, an `.xctest`
    /// bundle, or `XCTestConfigurationFilePath`) — the shipped app exhibits none,
    /// so it can't misfire in production (a missed detection only re-pollutes a
    /// test dir, never the reverse). Read-only (no mutable global) ⇒ parallel-safe.
    public static func home(fileManager: FileManager = .default) throws -> URL {
        let base: URL
        if isRunningUnderTests {
            base = fileManager.temporaryDirectory.appendingPathComponent("ProtelesTests", isDirectory: true)
        } else {
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            else { throw PathError.noDocumentsDirectory }
            base = documents
        }
        return try ensure(base.appendingPathComponent("Proteles", isDirectory: true), fileManager)
    }

    /// Whether the process is a test runner (never true in the shipped app).
    private static var isRunningUnderTests: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        let arg0 = CommandLine.arguments.first ?? ""
        if arg0.contains("swiftpm-testing-helper") || arg0.hasSuffix(".xctest") || arg0.contains("/xctest") {
            return true
        }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
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

    /// `~/Documents/Proteles/Sounds/` — the user's event-cue sounds (the
    /// soundpack's `.wav`s, #10). Proteles ships no audio with provenance
    /// risk; files arrive via the MUSHclient import (their own copies), a
    /// manual drop, or the optional CC0 default set. User files win.
    public static func soundsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("Sounds", isDirectory: true),
            fileManager
        )
    }

    /// `~/Documents/Proteles/MapImages/` — the user's map background textures
    /// (the per-area `texture` filenames the mapper DB references, e.g.
    /// `forest.png`). Proteles ships and imports **no** image files — the
    /// MUSHclient package's textures are GPL (issue #11); users who want them
    /// drop copies here themselves. A referenced file that isn't present just
    /// means a plain map background.
    public static func mapImagesDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensure(
            home(fileManager: fileManager).appendingPathComponent("MapImages", isDirectory: true),
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

    /// `Settings/notification-rules.json` — the hand-editable notification rules
    /// (mirrored from the `notificationRulesData` preference, #43/#45).
    public static func notificationRulesFile(fileManager: FileManager = .default) throws -> URL {
        try settingsDirectory(fileManager: fileManager).appendingPathComponent("notification-rules.json")
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

    /// `State/chat.sqlite` — the Chat window's channel-capture history DB (#57).
    public static func chatFile(fileManager: FileManager = .default) throws -> URL {
        try stateDirectory(fileManager: fileManager).appendingPathComponent("chat.sqlite")
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

    /// The per-character mapper **overlay**, `Databases/<character>/Aardwolf-personal.db`
    /// (D-111). Holds only that character's personal map data — portals, custom
    /// exits, exit level-locks, room notes, bookmarks — kept out of the shared
    /// `Aardwolf.db` so it doesn't bleed across characters. The distinctive name
    /// makes it unmistakable next to the shared file. Creates the per-character
    /// directory if needed.
    public static func personalMapperDatabaseURL(
        character: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try pluginDatabasesDirectory(character: character, fileManager: fileManager)
            .appendingPathComponent("Aardwolf-personal.db")
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

import Foundation
import MudCore
import Observation

/// A built-in native (Swift) plugin shown in the Plugins window, with its
/// live enabled state and displayable help.
public struct NativePluginRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let author: String
    public let version: String
    public let summary: String
    public let help: NativePluginHelp
    public var enabled: Bool
}

/// A built-in Proteles feature that started life as an Aardwolf MUSHclient
/// plugin and is now a native host (the graphical mapper, Search-and-Destroy).
/// Always present + active; listed so it's discoverable.
public struct BuiltInFeatureRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let commands: [String]
}

/// One plugin in the user's library, shown in the Plugins window: its parsed
/// name, its directory, where it came from (for the Update action), and its
/// per-world enabled state.
public struct LibraryPluginRow: Identifiable, Sendable, Equatable {
    /// The MUSHclient plugin id (stable identity).
    public let id: String
    public let name: String
    public let directory: URL
    public let origin: PluginOrigin
    /// `false` if the directory no longer resolves to a parseable plugin.
    public let parsed: Bool
    public var enabled: Bool
}

/// What's selected in the Plugins window: a built-in native plugin (by id), a
/// built-in feature (by id), or a library plugin (by MUSHclient id).
public enum PluginSelection: Hashable, Sendable {
    case native(String)
    case feature(String)
    case library(String)
}

/// `@Observable` model for the Plugins window: lists the user's library plugins
/// and the built-in native plugins, adds new ones from your Mac or a URL (with a
/// compatibility report), and removes/toggles/updates them. File operations live
/// here; re-syncing the live session is delegated to a `resync` closure the app
/// supplies (so a change applies immediately).
@MainActor
@Observable
public final class PluginsModel {
    /// The user's added plugins (the library).
    public private(set) var libraryPlugins: [LibraryPluginRow] = []
    /// Built-in native plugins registered on the session's engine.
    public private(set) var nativePlugins: [NativePluginRow] = []

    /// Built-in / bundled plugins surfaced in the Plugins window: the native
    /// mapper (always on), dinv (bundled), and Search & Destroy (installed on
    /// request — it's not shipped with the app).
    public let builtInFeatures: [BuiltInFeatureRow] = [
        BuiltInFeatureRow(
            id: "mapper",
            name: "Mapper",
            summary: "Native graphical GMCP mapper (a from-scratch reimplementation of "
                + "aard_GMCP_mapper). Auto-maps as you explore; pathfinds with portals/recalls; "
                + "reads/writes the MUSHclient Aardwolf.db schema so it shares the file other "
                + "plugins read. Import an existing Aardwolf.db via Databases ▸ Import Map Database.",
            commands: [
                "mapper goto|walkto <room|name> — speedwalk there",
                "mapper where|find <text> — search rooms by name",
                "mapper portals | portal | fullportal | delete portal — manage portals",
                "mapper cexit | cexits | fullcexit — custom exits",
                "mapper findpath <a> <b>, thisroom, unmapped, area, notes"
            ]
        ),
        BuiltInFeatureRow(
            id: "dinv",
            name: "dinv (Inventory)",
            summary: "The dinv inventory manager (MIT) — bundled and run verbatim through the "
                + "MUSHclient compatibility shim. Scans and identifies your whole inventory into a "
                + "per-character SQLite database for fast, stat-aware search.",
            commands: [
                "dinv build — scan + identify your full inventory",
                "dinv search <terms> — find items by stat / keyword",
                "dinv help — dinv's own command reference"
            ]
        ),
        BuiltInFeatureRow(
            id: "leveldb",
            name: "leveldb (Leveling DB)",
            summary: "The leveldb leveling database (MIT) — bundled and run verbatim through the "
                + "MUSHclient compatibility shim. Passively records kills, deaths, quests, "
                + "campaigns, global quests, power-ups, and level-ups into a SQLite database, "
                + "queried with its `ldb …` commands.",
            commands: [
                "ldb daily — today's leveling summary",
                "ldb level / ldb tier / ldb remort — progression breakdowns",
                "ldb campaigns / ldb quests / ldb gq — reward + completion logs",
                "ldb top xp / top zones / top mobs — most productive",
                "ldb help — leveldb's own command reference"
            ]
        ),
        BuiltInFeatureRow(
            id: "search-and-destroy",
            name: "Search & Destroy",
            summary: "The Search-and-Destroy campaign/quest hunter (by Crowley) — not bundled with "
                + "Proteles; install it on request from the Search & Destroy panel. It then runs its "
                + "own Lua on a dedicated sandboxed runtime with a native panel: detects "
                + "campaigns/quests, finds + navigates to targets, and keeps its own SnDdb.db.",
            commands: [
                "xcp — get the current campaign/quest target",
                "nx / nx- — go to the next / previous target",
                "xrt <area> — run to an area; go — go to room 1",
                "qs / qw / ht — quick-scan / quick-where / hunt-trick"
            ]
        )
    ]

    public var selection: PluginSelection?

    private let session: SessionController
    private var profileID: UUID?
    private var library: PluginLibraryStore?

    public init(session: SessionController) {
        self.session = session
    }

    /// The selected built-in feature (mapper / S&D), if one is selected.
    public var selectedFeature: BuiltInFeatureRow? {
        if case .feature(let id) = selection { return builtInFeatures.first { $0.id == id } }
        return nil
    }

    /// The selected built-in native plugin, if one is selected.
    public var selectedNative: NativePluginRow? {
        guard case .native(let id) = selection else { return nil }
        return nativePlugins.first { $0.id == id }
    }

    /// The selected library plugin, if one is selected.
    public var selectedLibrary: LibraryPluginRow? {
        guard case .library(let id) = selection else { return nil }
        return libraryPlugins.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Point the model at the active profile (for per-world enablement). Enable/
    /// disable/add/remove apply **hermetically** to the live session (load or
    /// unload just the one plugin via ``SessionController/enablePlugin(directory:character:)``
    /// / ``disablePlugin(id:directory:)``), not a full world reload.
    /// Call when the Plugins window appears / the active profile changes.
    public func prepare(profileID: UUID) {
        self.profileID = profileID
        library = (try? PluginLibraryStore.defaultStoreURL()).map { PluginLibraryStore(url: $0) }
    }

    /// The active character's data-dir key (for the per-character plugin data dir).
    private func characterKey() async -> String {
        guard let profileID else { return "" }
        return await ScriptsModel.characterKey(forProfile: profileID)
    }

    /// Load one plugin into the live session (hermetic enable).
    private func enableLive(_ directory: URL?) async {
        guard let directory else { return }
        await session.enablePlugin(directory: directory, character: characterKey())
    }

    /// Unload one plugin from the live session (hermetic disable).
    private func disableLive(_ pluginID: String, directory: URL?) async {
        await session.disablePlugin(id: pluginID, directory: directory)
    }

    /// Load the library from disk into displayable rows (parsing each plugin's
    /// `.xml` for its name + validity). Call when the window appears.
    public func refresh() async {
        guard let library, let profileID else { libraryPlugins = []; return }
        try? await library.load()
        libraryPlugins = await library.entries.map { entry in
            let directory = (try? entry.directory())
            let plugin = directory
                .flatMap { PluginInstaller.resolvePluginXML(at: $0) }
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? MUSHclientPluginLoader.parse($0) }
            let name = (plugin?.name).flatMap { $0.isEmpty ? nil : $0 } ?? entry.name
            return LibraryPluginRow(
                id: entry.pluginID,
                name: name,
                directory: directory ?? URL(fileURLWithPath: "/"),
                origin: entry.origin,
                parsed: plugin != nil,
                enabled: entry.isEnabled(forProfile: profileID)
            )
        }
    }

    /// Enable/disable a native plugin by id; applies live and persists the flag
    /// to the world's native-plugin store.
    public func setNativeEnabled(_ enabled: Bool, id: String) async {
        await session.setNativePluginEnabled(enabled, id: id)
        await refreshNative()
    }

    /// Load the built-in native plugins' current enabled state from the engine.
    public func refreshNative() async {
        let listing = await session.scriptEngine?.nativePluginListing() ?? []
        nativePlugins = listing.map {
            NativePluginRow(
                id: $0.metadata.id,
                name: $0.metadata.name,
                author: $0.metadata.author,
                version: $0.metadata.version,
                summary: $0.metadata.summary,
                help: $0.help,
                enabled: $0.enabled
            )
        }
    }

    // MARK: - Compatibility report

    /// Resolve the plugin `.xml` among `sources` (a folder, or loose files) and
    /// analyse it for the pre-add compatibility report. `nil` xml if none found.
    public func report(forSources sources: [URL]) -> (xml: URL?, report: PluginImportReport?) {
        let xml: URL? = if sources.count == 1 {
            PluginInstaller.findPluginXML(under: sources[0])
        } else {
            sources.first { $0.pathExtension.lowercased() == "xml" }
        }
        // The plugin's helpers travel with it: any `.lua` beside the `.xml` (and
        // any loose `.lua` the user picked) counts as present, so a folder add
        // doesn't warn about files it actually included.
        let available = Self.availableLuaFiles(xml: xml, sources: sources)
        let report = xml
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? MUSHclientPluginLoader.parse($0) }
            .map { PluginImporter.analyze($0, availableFiles: available) }
        return (xml, report)
    }

    /// Lowercased basenames of every `.lua` reachable from what's being added:
    /// the folder holding the `.xml` (recursively) plus any loose `.lua` sources.
    static func availableLuaFiles(xml: URL?, sources: [URL]) -> Set<String> {
        let fm = FileManager.default
        var names: Set<String> = []
        func addDirectory(_ dir: URL) {
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
            for case let file as URL in walker where file.pathExtension.lowercased() == "lua" {
                names.insert(file.lastPathComponent.lowercased())
            }
        }
        if let xml { addDirectory(xml.deletingLastPathComponent()) }
        for source in sources {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                addDirectory(source)
            } else if source.pathExtension.lowercased() == "lua" {
                names.insert(source.lastPathComponent.lowercased())
            }
        }
        return names
    }

    // MARK: - Add / remove / enable / update

    /// Stage a download from `url` into a temp directory (for the report +
    /// install). Throws on download/extract failure. The caller removes the temp
    /// dir when done.
    public func stageDownload(from url: URL) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-dl-\(UUID().uuidString)", isDirectory: true)
        try await PluginDownloader.download(from: url, into: temp)
        return temp
    }

    /// Install a plugin from local `sources` (a folder or loose files) into the
    /// library, enable it for the active world, and re-sync. `origin` overrides
    /// the recorded source (a URL, for a staged download). Returns the plugin id.
    @discardableResult
    public func add(sources: [URL], origin: PluginOrigin? = nil) async -> String? {
        guard let library, let profileID,
              let pluginsDir = try? ProtelesPaths.pluginsDirectory(),
              let result = try? PluginInstaller.installFromFiles(
                  sources, into: pluginsDir, origin: origin, enabledFor: profileID, now: Date()
              )
        else { return nil }
        // Re-adding a plugin already in the library: drop the old dir first (if
        // the new install landed in a different directory).
        let existing = await library.entries.first { $0.pluginID == result.entry.pluginID }
        if let existing, existing.dirName != result.entry.dirName, let oldDir = try? existing.directory() {
            try? FileManager.default.removeItem(at: oldDir)
        }
        try? await library.upsert(result.entry)
        await refresh()
        await enableLive(try? result.entry.directory())
        selection = .library(result.entry.pluginID)
        return result.entry.pluginID
    }

    /// Remove a plugin from the library — unload it from the live session, then
    /// delete its directory and the registry entry.
    public func remove(pluginID: String) async {
        guard let library else { return }
        let entry = await library.entries.first { $0.pluginID == pluginID }
        let dir = try? entry?.directory()
        await disableLive(pluginID, directory: dir)
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try? await library.remove(pluginID: pluginID)
        if selection == .library(pluginID) { selection = nil }
        await refresh()
    }

    /// Toggle a plugin for the active world: persist the per-world flag, then
    /// load or unload **just that plugin** in the live session (hermetic — other
    /// plugins + the mapper/S&D host keep running).
    public func setEnabled(_ enabled: Bool, pluginID: String) async {
        guard let library, let profileID else { return }
        let dir = try? await (library.entries.first { $0.pluginID == pluginID })?.directory()
        try? await library.setEnabled(enabled, pluginID: pluginID, forProfile: profileID)
        await refresh()
        if enabled {
            await enableLive(dir)
        } else {
            await disableLive(pluginID, directory: dir)
        }
    }

    /// Replace a plugin's files from new local `sources`, preserving its
    /// per-world enablement, then re-sync. (The "Update from file…" action.)
    public func updateFromFiles(pluginID: String, sources: [URL]) async {
        await replace(pluginID: pluginID, sources: sources, origin: .file(path: sources.first?.path ?? ""))
    }

    /// Re-download a URL-sourced plugin from its recorded origin and replace its
    /// files, preserving enablement. (The "Refresh" action.) No-op for a
    /// file-sourced plugin (use `updateFromFiles`).
    public func refreshFromURL(pluginID: String) async {
        guard let library,
              let entry = await library.entries.first(where: { $0.pluginID == pluginID }),
              case .url(let urlString) = entry.origin, let url = URL(string: urlString)
        else { return }
        guard let temp = try? await stageDownload(from: url) else { return }
        defer { try? FileManager.default.removeItem(at: temp) }
        await replace(pluginID: pluginID, sources: [temp], origin: .url(urlString))
    }

    /// Shared replace: unload the old plugin live, drop the old dir, install
    /// fresh, then re-load the new files live (if still enabled). Keeps the old
    /// enablement. Hermetic — other plugins are untouched.
    private func replace(pluginID: String, sources: [URL], origin: PluginOrigin) async {
        guard let library, let profileID,
              let old = await library.entries.first(where: { $0.pluginID == pluginID }),
              let pluginsDir = try? ProtelesPaths.pluginsDirectory()
        else { return }
        let oldDir = try? old.directory()
        await disableLive(pluginID, directory: oldDir)
        if let oldDir { try? FileManager.default.removeItem(at: oldDir) }
        guard let result = try? PluginInstaller.installFromFiles(
            sources, into: pluginsDir, origin: origin, enabledFor: profileID, now: Date()
        ) else { return }
        var entry = result.entry
        entry.enabledProfiles = old.enabledProfiles
        entry.addedAt = old.addedAt
        entry.updatedAt = Date()
        // The id may differ if the file changed identity; drop the stale entry.
        if entry.pluginID != pluginID { try? await library.remove(pluginID: pluginID) }
        try? await library.upsert(entry)
        await refresh()
        if entry.enabledProfiles.contains(profileID) {
            await enableLive(try? entry.directory())
        }
    }
}

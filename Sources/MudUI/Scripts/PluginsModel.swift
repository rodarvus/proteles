import Foundation
import MudCore
import Observation

/// A MUSHclient plugin installed for a world: the on-disk `.xml` plus parsed
/// metadata for display.
public struct InstalledPlugin: Identifiable, Sendable, Equatable {
    /// The file URL (also the stable identity).
    public let id: URL
    public let name: String
    public let author: String
    public let version: String
    /// `false` if the file couldn't be parsed as a plugin.
    public let parsed: Bool

    public var fileName: String {
        id.lastPathComponent
    }
}

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

/// A **personal** plugin referenced in place from the user's own disk (never
/// copied into app-support), shown in the Plugins window with its parsed name,
/// source path, and per-world enabled state.
public struct LocalPluginRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    /// `false` if the referenced path no longer resolves to a parseable plugin.
    public let parsed: Bool
    public var enabled: Bool
}

/// What's selected in the Plugins window: a built-in native plugin (by id),
/// an imported `.xml` plugin (by file URL), a local plugin (by reference
/// id), or a built-in feature (by id).
public enum PluginSelection: Hashable, Sendable {
    case native(String)
    case imported(URL)
    case local(UUID)
    case feature(String)
}

/// `@Observable` model for the Plugins window: lists a world's installed
/// `.xml` plugins and the built-in native plugins, imports new ones (with a
/// compatibility report), and removes/toggles them. File operations live
/// here; re-syncing the live session is delegated to a `resync` closure the
/// app supplies (so a change applies immediately).
@MainActor
@Observable
public final class PluginsModel {
    public private(set) var installed: [InstalledPlugin] = []
    /// Personal plugins referenced in place from the user's own disk.
    public private(set) var localPlugins: [LocalPluginRow] = []
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
    private var directory: URL?
    private var localStore: LocalPluginStore?
    private var resync: (@MainActor () async -> Void)?

    public init(session: SessionController) {
        self.session = session
    }

    /// The selected imported plugin's file URL, if an imported plugin (not a
    /// native one) is selected — used by the import/remove flow.
    public var selectedImportedURL: URL? {
        if case .imported(let url) = selection { return url }
        return nil
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

    /// The selected local plugin, if one is selected.
    public var selectedLocal: LocalPluginRow? {
        guard case .local(let id) = selection else { return nil }
        return localPlugins.first { $0.id == id }
    }

    /// Load the built-in native plugins' current enabled state from the
    /// engine. Call when the Plugins window appears.
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

    /// Enable/disable a native plugin by id; applies live and persists the
    /// flag to the world's native-plugin store.
    public func setNativeEnabled(_ enabled: Bool, id: String) async {
        await session.setNativePluginEnabled(enabled, id: id)
        await refreshNative()
    }

    /// Point the model at a world's plugins directory and supply the
    /// re-sync action (typically reloading the active profile's scripts +
    /// plugins). Call when the Plugins window appears.
    public func prepare(directory: URL, resync: @escaping @MainActor () async -> Void) {
        self.directory = directory
        self.resync = resync
        // Personal-plugin references live beside the imported plugins (the
        // loader scans only `.xml`, so the `.json` is ignored there).
        localStore = LocalPluginStore(url: directory.appendingPathComponent("local-plugins.json"))
        refresh()
    }

    /// Load the world's local-plugin references from disk into displayable
    /// rows (parsing each referenced `.xml` for its name). Call when the window
    /// appears, alongside ``refreshNative()``.
    public func refreshLocal() async {
        guard let localStore else { localPlugins = []; return }
        try? await localStore.load()
        localPlugins = await localStore.plugins.map { reference in
            let plugin = LocalPluginStore.resolvePluginXML(at: reference.url)
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? MUSHclientPluginLoader.parse($0) }
            let name = (plugin?.name).flatMap { $0.isEmpty ? nil : $0 } ?? reference.url.lastPathComponent
            return LocalPluginRow(
                id: reference.id,
                name: name,
                path: reference.path,
                parsed: plugin != nil,
                enabled: reference.enabled
            )
        }
    }

    /// Reference a local plugin at `url` (a `.xml` or its folder), load it
    /// live, and persist the reference per-world. Returns `false` if the path
    /// doesn't resolve to a plugin `.xml`.
    @discardableResult
    public func addLocalPlugin(at url: URL) async -> Bool {
        guard let localStore, LocalPluginStore.resolvePluginXML(at: url) != nil else { return false }
        let reference = LocalPluginReference(path: url.path)
        try? await localStore.add(reference)
        await refreshLocal()
        await resync?()
        selection = .local(reference.id)
        return true
    }

    /// Drop a local-plugin reference (the file on disk is untouched) and
    /// re-sync so it stops loading.
    public func removeLocal(id: UUID) async {
        guard let localStore else { return }
        try? await localStore.remove(id: id)
        if selection == .local(id) { selection = nil }
        await refreshLocal()
        await resync?()
    }

    /// Toggle a local plugin for this world and re-sync (a disabled plugin
    /// isn't reloaded).
    public func setLocalEnabled(_ enabled: Bool, id: UUID) async {
        guard let localStore else { return }
        try? await localStore.setEnabled(enabled, id: id)
        await refreshLocal()
        await resync?()
    }

    /// Re-scan the directory for `.xml` plugins.
    public func refresh() {
        guard let directory else { installed = []; return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        installed = urls
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Self.describe)
    }

    /// Parse + analyse a candidate file for the import preview. `nil` if it
    /// isn't a parseable plugin.
    public func report(for url: URL) -> PluginImportReport? {
        guard let data = try? Data(contentsOf: url),
              let plugin = try? MUSHclientPluginLoader.parse(data)
        else { return nil }
        return PluginImporter.analyze(plugin)
    }

    /// Copy `sourceURL` into the world's plugins directory and re-sync the
    /// live session so it loads immediately. Returns the installed entry's id.
    @discardableResult
    public func install(from sourceURL: URL) async -> URL? {
        guard let directory else { return nil }
        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            return nil
        }
        refresh()
        await resync?()
        return destination
    }

    /// Delete an installed plugin's file and re-sync.
    public func remove(_ plugin: InstalledPlugin) async {
        try? FileManager.default.removeItem(at: plugin.id)
        if selection == .imported(plugin.id) { selection = nil }
        refresh()
        await resync?()
    }

    // MARK: - Private

    private static func describe(_ url: URL) -> InstalledPlugin {
        guard let data = try? Data(contentsOf: url),
              let plugin = try? MUSHclientPluginLoader.parse(data)
        else {
            return InstalledPlugin(
                id: url, name: url.lastPathComponent, author: "", version: "", parsed: false
            )
        }
        return InstalledPlugin(
            id: url,
            name: plugin.name.isEmpty ? url.lastPathComponent : plugin.name,
            author: plugin.author,
            version: plugin.version,
            parsed: true
        )
    }
}

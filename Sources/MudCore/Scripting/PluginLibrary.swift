import Foundation

/// Where a library plugin came from — used only by the **manual** Update action.
/// There is no auto-fetch; the user explicitly re-copies or re-downloads.
public enum PluginOrigin: Codable, Sendable, Equatable {
    /// Copied from this local path (a file or a folder the user picked).
    /// "Update from file…" re-copies from here (or a newly chosen path).
    case file(path: String)
    /// Downloaded from this URL. "Refresh" re-downloads from here.
    case url(String)
}

/// One plugin in the user's library: a self-contained directory under
/// `~/Documents/Proteles/Plugins/<dirName>/`. Identity is the MUSHclient plugin
/// id parsed from its `.xml`; the directory and code are **global** (shared
/// across characters) while the **enabled** flag is per-character (per profile).
public struct PluginLibraryEntry: Codable, Sendable, Equatable, Identifiable {
    /// The MUSHclient plugin id (from `<plugin id="…">`) — the dedup/identity key.
    public let pluginID: String
    /// Display name (from the plugin `.xml`).
    public var name: String
    /// The plugin's subdirectory name under the Plugins home.
    public var dirName: String
    /// Where it came from (for the manual Update action).
    public var origin: PluginOrigin
    /// The profiles (characters) this plugin is enabled for — code is global,
    /// enablement is per-character.
    public var enabledProfiles: Set<UUID>
    public var addedAt: Date?
    public var updatedAt: Date?

    public var id: String {
        pluginID
    }

    public init(
        pluginID: String,
        name: String,
        dirName: String,
        origin: PluginOrigin,
        enabledProfiles: Set<UUID> = [],
        addedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.pluginID = pluginID
        self.name = name
        self.dirName = dirName
        self.origin = origin
        self.enabledProfiles = enabledProfiles
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    public func isEnabled(forProfile profile: UUID) -> Bool {
        enabledProfiles.contains(profile)
    }

    /// This plugin's directory under `~/Documents/Proteles/Plugins/`.
    public func directory(fileManager: FileManager = .default) throws -> URL {
        try ProtelesPaths.pluginDirectory(named: dirName, fileManager: fileManager)
    }
}

/// The persisted plugin-library registry — the authoritative list of plugins the
/// user has explicitly added (a registry, not a folder scan, so a raw directory
/// dropped into `Plugins/` is ignored until formally added).
public struct PluginLibraryDocument: Codable, Sendable, Equatable {
    public var entries: [PluginLibraryEntry]

    public init(entries: [PluginLibraryEntry] = []) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case entries }

    /// A missing `entries` key decodes as empty rather than failing the load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([PluginLibraryEntry].self, forKey: .entries) ?? []
    }
}

/// Actor owning the plugin-library registry and persisting it atomically,
/// mirroring ``ScriptStore``/``LocalPluginStore``. The registry is **global**
/// (one file, all characters); per-character enablement lives on each entry.
/// Storage only — the session loads the referenced plugin directories.
public actor PluginLibraryStore {
    public enum StoreError: Error, Equatable {
        case loadFailed(String)
        case saveFailed(String)
        case notFound(String)
    }

    public let url: URL
    public private(set) var entries: [PluginLibraryEntry] = []

    public init(url: URL) {
        self.url = url
    }

    public var document: PluginLibraryDocument {
        PluginLibraryDocument(entries: entries)
    }

    // MARK: - Load / mutate

    /// Load the registry. A missing file is an empty library (nothing is written
    /// until the first edit).
    public func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = []
            return
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
        do {
            entries = try JSONDecoder().decode(PluginLibraryDocument.self, from: data).entries
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
    }

    /// Add a new entry, or replace an existing one with the same plugin id
    /// (re-adding a plugin updates it in place rather than duplicating).
    public func upsert(_ entry: PluginLibraryEntry) throws {
        if let index = entries.firstIndex(where: { $0.pluginID == entry.pluginID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persist()
    }

    public func remove(pluginID: String) throws {
        guard entries.contains(where: { $0.pluginID == pluginID }) else {
            throw StoreError.notFound(pluginID)
        }
        entries.removeAll { $0.pluginID == pluginID }
        try persist()
    }

    /// Toggle a plugin's enablement for one profile (character).
    public func setEnabled(_ enabled: Bool, pluginID: String, forProfile profile: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.pluginID == pluginID }) else {
            throw StoreError.notFound(pluginID)
        }
        if enabled {
            entries[index].enabledProfiles.insert(profile)
        } else {
            entries[index].enabledProfiles.remove(profile)
        }
        try persist()
    }

    /// Record a manual Update (new origin + bump `updatedAt`).
    public func recordUpdate(pluginID: String, origin: PluginOrigin, at date: Date) throws {
        guard let index = entries.firstIndex(where: { $0.pluginID == pluginID }) else {
            throw StoreError.notFound(pluginID)
        }
        entries[index].origin = origin
        entries[index].updatedAt = date
        try persist()
    }

    /// The plugins enabled for `profile`, in registry order.
    public func enabled(forProfile profile: UUID) -> [PluginLibraryEntry] {
        entries.filter { $0.isEnabled(forProfile: profile) }
    }

    // MARK: - Disk

    /// The global registry location:
    /// `~/Library/Application Support/com.proteles.ProtelesApp/plugin-library.json`.
    /// `~/Documents/Proteles/Settings/plugin-library.json` (#43) — the installed-
    /// plugin registry + per-world enablement, alongside the rest of the config.
    public static func defaultStoreURL(fileManager: FileManager = .default) throws -> URL {
        try ProtelesPaths.pluginLibraryFile(fileManager: fileManager)
    }

    private func persist() throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }
}

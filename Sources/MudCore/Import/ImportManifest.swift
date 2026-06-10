import Foundation

/// The reviewable result of scanning a MUSHclient install: everything Proteles
/// found and what it proposes to do, for the user to confirm/adjust before any
/// writing. Pure value type.
///
/// **Privacy:** the manifest is the displayable/loggable artifact, so it carries
/// **no secrets** — the autologin password is *not* here (it stays on the parsed
/// ``MUSHclientWorldFile/password`` and goes straight to the Keychain at import);
/// the manifest only records ``WorldSummary/hasPassword``.
public struct ImportManifest: Sendable, Equatable {
    public var world: WorldSummary
    public var plugins: [PluginEntry]
    /// Databases found in the install, typed (mapper / S&D / dinv-per-character /
    /// leveldb / plugin-owned / unknown). The user chooses which to import.
    public var databases: [DatabaseEntry]
    /// Parsed plugin state (`{worldID}-{pluginID}-state.xml` → variables), keyed
    /// by plugin id — seeds the variable store for imported (non-package) plugins.
    public var stateFiles: [StateFile]
    /// Things that couldn't be scanned/parsed — surfaced to the user and the
    /// "Report on GitHub" path (#feature). Never fatal.
    public var problems: [Problem]
    /// The install's map background textures (`worlds/plugins/images/`), if the
    /// folder exists — copied to `~/Documents/Proteles/MapImages/` at import.
    /// The user's own copies; Proteles still bundles none (GPL, #11).
    public var mapImages: MapImagesEntry?
    /// The install's own Search & Destroy copy, when one exists. Proteles
    /// provides S&D natively (latest release, tested) and that stays the
    /// default — but a user running a customised/beta S&D can choose to
    /// import THEIR copy instead (#53: the host loads any S&D source now,
    /// injecting the panel bridge at load).
    public var searchAndDestroy: SearchAndDestroyEntry?

    public init(
        world: WorldSummary,
        plugins: [PluginEntry] = [],
        databases: [DatabaseEntry] = [],
        stateFiles: [StateFile] = [],
        problems: [Problem] = [],
        mapImages: MapImagesEntry? = nil,
        searchAndDestroy: SearchAndDestroyEntry? = nil
    ) {
        self.world = world
        self.plugins = plugins
        self.databases = databases
        self.stateFiles = stateFiles
        self.problems = problems
        self.mapImages = mapImages
        self.searchAndDestroy = searchAndDestroy
    }

    /// The map-texture folder found in the install.
    public struct MapImagesEntry: Sendable, Equatable {
        public var directory: URL
        /// How many image files it holds (for the review sheet).
        public var count: Int

        public init(directory: URL, count: Int) {
            self.directory = directory
            self.count = count
        }
    }

    /// The install's S&D folder (holds `Search_and_Destroy.xml` + its `lua/`
    /// modules).
    public struct SearchAndDestroyEntry: Sendable, Equatable {
        public var directory: URL

        public init(directory: URL) {
            self.directory = directory
        }
    }

    /// Reclassify offer plugins whose id is already in Proteles' library as
    /// ``Classification/alreadyInstalled``, so they aren't re-offered. Applied by
    /// the app after scanning (the pure scanner has no app state).
    public func markingAlreadyInstalled(pluginIDs: Set<String>) -> ImportManifest {
        var copy = self
        copy.plugins = plugins.map { entry in
            guard entry.classification == .offer,
                  let id = entry.pluginID, pluginIDs.contains(id) else { return entry }
            var updated = entry
            updated.classification = .alreadyInstalled
            return updated
        }
        return copy
    }

    /// Connection + macro summary (no password — see the manifest's privacy note).
    public struct WorldSummary: Sendable, Equatable {
        public var name: String
        public var host: String
        public var port: UInt16
        public var username: String
        public var hasPassword: Bool
        public var macroCount: Int

        public init(
            name: String,
            host: String,
            port: UInt16,
            username: String,
            hasPassword: Bool,
            macroCount: Int
        ) {
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.hasPassword = hasPassword
            self.macroCount = macroCount
        }
    }

    /// One enabled plugin, resolved on disk and classified.
    public struct PluginEntry: Sendable, Equatable, Identifiable {
        /// The original `<include>` path (`dinv\dinv.xml`) — unique per world.
        public var include: String
        public var filename: String
        public var pluginID: String?
        public var name: String?
        /// The plugin's `.xml` on disk (nil if the include didn't resolve).
        public var resolvedPath: URL?
        /// The directory/file to copy on import: the containing subdir for a
        /// multi-file plugin, else the single `.xml`.
        public var copyRoot: URL?
        public var isMultiFile: Bool
        public var classification: Classification
        /// The plugin's own SQLite database file(s), found in its
        /// `state/<name>-<id>/` directory (or referenced via `GetInfo(66)`). These
        /// travel **with** the plugin — copied to the runtime DB dir
        /// (`Databases/<character>/`) on import — so they're not separate choices.
        public var dataFiles: [URL]
        /// Data files the plugin reads relative to `GetInfo(56/60/64)` (e.g. the
        /// message gagger's `messages_to_gag.txt` at the MUSHclient root). Proteles
        /// maps `GetInfo(56)` to the plugin's own folder, so these are copied
        /// **into** `Plugins/<name>/` on install.
        public var pluginDirSidecars: [URL]
        /// Compatibility report (the same `PluginImporter.analyze` due-diligence
        /// the manual "add a plugin" flow shows) — verdict + findings, so the
        /// review UI can flag plugins that won't fully work. `nil` if unparsed.
        public var report: PluginImportReport?

        public var id: String {
            include
        }

        public init(
            include: String,
            filename: String,
            pluginID: String?,
            name: String?,
            resolvedPath: URL?,
            copyRoot: URL?,
            isMultiFile: Bool,
            classification: Classification,
            dataFiles: [URL] = [],
            pluginDirSidecars: [URL] = [],
            report: PluginImportReport? = nil
        ) {
            self.include = include
            self.filename = filename
            self.pluginID = pluginID
            self.name = name
            self.resolvedPath = resolvedPath
            self.copyRoot = copyRoot
            self.isMultiFile = isMultiFile
            self.classification = classification
            self.dataFiles = dataFiles
            self.pluginDirSidecars = pluginDirSidecars
            self.report = report
        }
    }

    /// What the importer proposes for a plugin.
    public enum Classification: String, Sendable, Equatable {
        /// In aardwolfclientpackage — Proteles provides it; skip (not offered).
        case package
        /// dinv/leveldb/S&D — Proteles bundles the code; import the data only.
        case bundled
        /// Third-party — offer to import (user chooses).
        case offer
        /// An offer plugin already present in Proteles' plugin library — not
        /// re-offered (avoids duplicate installs).
        case alreadyInstalled
    }

    /// A database found in the install, typed by name/path.
    public struct DatabaseEntry: Sendable, Equatable, Identifiable {
        public var url: URL
        public var kind: DatabaseKind
        /// The character a per-character database belongs to (dinv), else nil.
        public var character: String?
        public var byteSize: Int
        /// Last-modified time — used to pick the **live** mapper/S&D DB when an
        /// install holds several copies.
        public var modified: Date

        public var id: String {
            url.path
        }

        public init(
            url: URL,
            kind: DatabaseKind,
            character: String? = nil,
            byteSize: Int,
            modified: Date = .distantPast
        ) {
            self.url = url
            self.kind = kind
            self.character = character
            self.byteSize = byteSize
            self.modified = modified
        }
    }

    /// What Proteles feature a database maps to.
    public enum DatabaseKind: String, Sendable, Equatable {
        case mapper // Aardwolf.db → native mapper
        case searchAndDestroy // SnDdb.db
        case dinv // per-character dinv.db
        case leveldb // leveldb.db
        case pluginOwned // a third-party plugin's own db
        case unknown // found, type not recognised — user decides
    }

    /// Parsed `<variables>` from a plugin's MUSHclient state file.
    public struct StateFile: Sendable, Equatable {
        public var pluginID: String
        public var variables: [String: String]

        public init(pluginID: String, variables: [String: String]) {
            self.pluginID = pluginID
            self.variables = variables
        }
    }

    /// A scan/parse failure, for display + the GitHub-report path.
    public struct Problem: Sendable, Equatable {
        public var item: String
        public var reason: String

        public init(item: String, reason: String) {
            self.item = item
            self.reason = reason
        }
    }
}

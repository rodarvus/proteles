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

    public init(
        world: WorldSummary,
        plugins: [PluginEntry] = [],
        databases: [DatabaseEntry] = [],
        stateFiles: [StateFile] = [],
        problems: [Problem] = []
    ) {
        self.world = world
        self.plugins = plugins
        self.databases = databases
        self.stateFiles = stateFiles
        self.problems = problems
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
            classification: Classification
        ) {
            self.include = include
            self.filename = filename
            self.pluginID = pluginID
            self.name = name
            self.resolvedPath = resolvedPath
            self.copyRoot = copyRoot
            self.isMultiFile = isMultiFile
            self.classification = classification
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

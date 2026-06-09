import Foundation

/// The reviewable result of scanning a MUSHclient install: everything Proteles
/// found and what it proposes to do, for the user to confirm/adjust before any
/// writing. Pure value type.
///
/// **Privacy:** the manifest is the displayable/loggable artifact, so it carries
/// **no secrets** — the autologin password is *not* here (see
/// ``MUSHclientInstallScan/password``); only ``WorldSummary/hasPassword``.
public struct ImportManifest: Sendable, Equatable {
    public var world: WorldSummary
    public var plugins: [PluginEntry]
    /// Things that couldn't be scanned/parsed — surfaced to the user and the
    /// "Report on GitHub" path (#feature). Never fatal.
    public var problems: [Problem]

    public init(world: WorldSummary, plugins: [PluginEntry] = [], problems: [Problem] = []) {
        self.world = world
        self.plugins = plugins
        self.problems = problems
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

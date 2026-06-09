import Foundation

/// The MUSHclient import coordinator (P2): given a parsed world, its scan
/// ``ImportManifest``, and the user's ``Selection``, it sequences every
/// sub-importer — profile + autologin, macros + keypad, offer plugins + their
/// state, and the chosen databases — into one operation, collecting non-fatal
/// problems for the report path.
///
/// The caller (the app) is responsible for backing up `~/Documents/Proteles`
/// before invoking this; the coordinator only writes.
public enum MUSHclientImporter {
    /// What the user chose to import (assembled by the review UI).
    public struct Selection: Sendable {
        /// Import the keypad + macros.
        public var importScriptsAndKeypad: Bool
        /// `<include>` paths of the offer plugins to install.
        public var pluginIncludes: Set<String>
        /// `id`s (file paths) of the databases to copy.
        public var databasePaths: Set<String>
        /// New profile vs merge into an existing one.
        public var target: ProfileImporter.Target
        /// Target character for per-character scripts/keypad + character-less DBs.
        public var character: String

        public init(
            importScriptsAndKeypad: Bool,
            pluginIncludes: Set<String>,
            databasePaths: Set<String>,
            target: ProfileImporter.Target,
            character: String
        ) {
            self.importScriptsAndKeypad = importScriptsAndKeypad
            self.pluginIncludes = pluginIncludes
            self.databasePaths = databasePaths
            self.target = target
            self.character = character
        }
    }

    /// The stores + paths the import writes into.
    public struct Environment: Sendable {
        public var profiles: ProfileStore
        public var credentials: any CredentialStore
        public var library: PluginLibraryStore
        public var pluginsDirectory: URL
        public var databasesDirectory: URL
        public var makeScriptStore: @Sendable (String) -> ScriptStore
        public var makeVariableStore: @Sendable (UUID) -> VariableStore
        public var now: Date

        public init(
            profiles: ProfileStore,
            credentials: any CredentialStore,
            library: PluginLibraryStore,
            pluginsDirectory: URL,
            databasesDirectory: URL,
            makeScriptStore: @escaping @Sendable (String) -> ScriptStore,
            makeVariableStore: @escaping @Sendable (UUID) -> VariableStore,
            now: Date
        ) {
            self.profiles = profiles
            self.credentials = credentials
            self.library = library
            self.pluginsDirectory = pluginsDirectory
            self.databasesDirectory = databasesDirectory
            self.makeScriptStore = makeScriptStore
            self.makeVariableStore = makeVariableStore
            self.now = now
        }
    }

    public struct Result: Sendable {
        public var profileID: UUID
        public var problems: [ImportManifest.Problem]
    }

    public static func run(
        world: MUSHclientWorldFile,
        manifest: ImportManifest,
        selection: Selection,
        into env: Environment
    ) async throws -> Result {
        var problems = manifest.problems

        // 1. Profile + autologin (password → Keychain).
        let profileID = try await ProfileImporter.apply(
            world: world,
            target: selection.target,
            profiles: env.profiles,
            credentials: env.credentials
        )

        // 2. Macros + keypad (per character).
        if selection.importScriptsAndKeypad {
            let store = env.makeScriptStore(selection.character)
            try await store.load()
            try await ScriptImporter.apply(
                macros: MUSHclientMacroMapping.macros(from: world.macros),
                keypad: MUSHclientKeypadMapping.keypad(from: world.keypad),
                aliases: MUSHclientScriptMapping.aliases(from: world.aliases),
                triggers: MUSHclientScriptMapping.triggers(from: world.triggers),
                into: store
            )
        }

        // 3. Offer plugins + their saved state.
        let selectedPlugins = manifest.plugins.filter { selection.pluginIncludes.contains($0.include) }
        let variables = env.makeVariableStore(profileID)
        try await variables.load()
        let pluginEnv = MUSHclientPluginImporter.Environment(
            profile: profileID,
            pluginsDirectory: env.pluginsDirectory,
            library: env.library,
            variables: variables,
            now: env.now
        )
        problems += try await MUSHclientPluginImporter.apply(
            plugins: selectedPlugins,
            stateFiles: manifest.stateFiles,
            into: pluginEnv
        )

        // 3b. Plugin-owned data files travel with their plugin → the runtime DB
        // dir (Databases/<character>/), so the plugin finds them after import.
        for plugin in selectedPlugins where plugin.classification == .offer {
            for dataFile in plugin.dataFiles {
                do {
                    try DatabaseImporter.copy(
                        .init(url: dataFile, kind: .pluginOwned, byteSize: 0),
                        character: selection.character,
                        in: env.databasesDirectory
                    )
                } catch {
                    problems.append(.init(
                        item: dataFile.lastPathComponent, reason: error.localizedDescription
                    ))
                }
            }
        }

        // 4. Databases.
        for database in manifest.databases where selection.databasePaths.contains(database.id) {
            do {
                try DatabaseImporter.copy(
                    database, character: selection.character, in: env.databasesDirectory
                )
            } catch {
                problems.append(.init(
                    item: database.url.lastPathComponent, reason: error.localizedDescription
                ))
            }
        }

        return Result(profileID: profileID, problems: problems)
    }
}

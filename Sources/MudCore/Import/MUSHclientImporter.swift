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
        /// Replace Proteles' Search & Destroy with the scanned install's copy
        /// (an UNTESTED version — Proteles' own, the latest release, stays the
        /// recommended default, so this is opt-in per import).
        public var importSearchAndDestroyCode: Bool

        public init(
            importScriptsAndKeypad: Bool,
            pluginIncludes: Set<String>,
            databasePaths: Set<String>,
            target: ProfileImporter.Target,
            character: String,
            importSearchAndDestroyCode: Bool = false
        ) {
            self.importScriptsAndKeypad = importScriptsAndKeypad
            self.pluginIncludes = pluginIncludes
            self.databasePaths = databasePaths
            self.target = target
            self.character = character
            self.importSearchAndDestroyCode = importSearchAndDestroyCode
        }
    }

    /// The stores + paths the import writes into.
    public struct Environment: Sendable {
        public var profiles: ProfileStore
        public var credentials: any CredentialStore
        public var library: PluginLibraryStore
        public var pluginsDirectory: URL
        public var databasesDirectory: URL
        /// Destination for the install's map background textures
        /// (`~/Documents/Proteles/MapImages/`); nil skips that step.
        public var mapImagesDirectory: URL?
        /// Proteles' S&D install dir (`Plugins/search-and-destroy/`), the
        /// destination when the user opts to import THEIR S&D copy; nil
        /// skips that step.
        public var searchAndDestroyDirectory: URL?
        public var makeScriptStore: @Sendable (String) -> ScriptStore
        public var makeVariableStore: @Sendable (UUID) -> VariableStore
        public var now: Date

        public init(
            profiles: ProfileStore,
            credentials: any CredentialStore,
            library: PluginLibraryStore,
            pluginsDirectory: URL,
            databasesDirectory: URL,
            mapImagesDirectory: URL? = nil,
            searchAndDestroyDirectory: URL? = nil,
            makeScriptStore: @escaping @Sendable (String) -> ScriptStore,
            makeVariableStore: @escaping @Sendable (UUID) -> VariableStore,
            now: Date
        ) {
            self.profiles = profiles
            self.credentials = credentials
            self.library = library
            self.pluginsDirectory = pluginsDirectory
            self.databasesDirectory = databasesDirectory
            self.mapImagesDirectory = mapImagesDirectory
            self.searchAndDestroyDirectory = searchAndDestroyDirectory
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
                timers: MUSHclientScriptMapping.timers(from: world.timers),
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
        problems += copyPluginDataFiles(
            selectedPlugins, character: selection.character, into: env.databasesDirectory
        )

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

        // 5. Map background textures (worlds/plugins/images → MapImages/) —
        // the user's own copies, so no licensing issue arises (#11 concerns
        // Proteles *shipping* them, which it still doesn't). Existing files
        // are kept (re-imports never clobber a user's customised texture).
        if let images = manifest.mapImages, let destination = env.mapImagesDirectory {
            problems += copyMapImages(from: images.directory, to: destination)
        }

        // 6. The install's own S&D, only when the user opted in (Proteles'
        // tested copy is the default; #53 lets the host run either — the
        // panel bridge injects at load). Their XML + lua modules REPLACE
        // same-named files; our split core.lua stays as the inert fallback.
        if selection.importSearchAndDestroyCode, let theirs = manifest.searchAndDestroy {
            if let destination = env.searchAndDestroyDirectory {
                problems += copySearchAndDestroy(from: theirs.directory, to: destination)
            }
        }

        return Result(profileID: profileID, problems: problems)
    }

    /// Copy the install's S&D plugin files (the XML + every `.lua` beside it
    /// or in its `lua/` subfolder) over ours. Best-effort; failures become
    /// problems.
    private static func copySearchAndDestroy(
        from source: URL,
        to destination: URL
    ) -> [ImportManifest.Problem] {
        let fileManager = FileManager.default
        var problems: [ImportManifest.Problem] = []
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var files = [source.appendingPathComponent("Search_and_Destroy.xml")]
        for folder in [source, source.appendingPathComponent("lua")] {
            let items = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) ?? []
            files += items.filter { $0.pathExtension.lowercased() == "lua" }
        }
        for file in files where fileManager.fileExists(atPath: file.path) {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: file, to: target)
            } catch {
                problems.append(.init(
                    item: file.lastPathComponent, reason: error.localizedDescription
                ))
            }
        }
        return problems
    }

    /// Copy every image file, skipping ones already present. Best-effort;
    /// failures become problems.
    private static func copyMapImages(from source: URL, to destination: URL) -> [ImportManifest.Problem] {
        let extensions: Set = ["png", "jpg", "jpeg", "gif", "bmp"]
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil
        ) else { return [] }
        var problems: [ImportManifest.Problem] = []
        for file in items where extensions.contains(file.pathExtension.lowercased()) {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.copyItem(at: file, to: target)
            } catch {
                problems.append(.init(
                    item: file.lastPathComponent, reason: error.localizedDescription
                ))
            }
        }
        return problems
    }

    /// Copy each selected offer plugin's own data files into the per-character DB
    /// dir. Best-effort; failures become problems.
    private static func copyPluginDataFiles(
        _ plugins: [ImportManifest.PluginEntry],
        character: String,
        into databasesDirectory: URL
    ) -> [ImportManifest.Problem] {
        var problems: [ImportManifest.Problem] = []
        for plugin in plugins where plugin.classification == .offer {
            for dataFile in plugin.dataFiles {
                do {
                    try DatabaseImporter.copy(
                        .init(url: dataFile, kind: .pluginOwned, byteSize: 0),
                        character: character,
                        in: databasesDirectory
                    )
                } catch {
                    problems.append(.init(
                        item: dataFile.lastPathComponent, reason: error.localizedDescription
                    ))
                }
            }
        }
        return problems
    }
}

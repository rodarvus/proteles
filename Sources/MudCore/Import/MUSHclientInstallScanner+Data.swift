import Foundation

/// Database + plugin-state scanning, and the top-level orchestration that
/// assembles the full ``ImportManifest``. Split from the plugin scanner to keep
/// each file focused.
public extension MUSHclientInstallScanner {
    /// Scan a whole MUSHclient install (the directory containing `worlds/`) plus
    /// the already-parsed world file into a complete manifest.
    static func scan(root: URL, world: MUSHclientWorldFile) -> ImportManifest {
        let pluginsDirectory = root.appendingPathComponent("worlds/plugins")
        let (plugins, problems) = scanPlugins(world: world, pluginsDirectory: pluginsDirectory)
        let summary = ImportManifest.WorldSummary(
            name: world.name,
            host: world.host,
            port: world.port,
            username: world.username,
            hasPassword: world.password != nil,
            macroCount: world.macros.count
        )
        return ImportManifest(
            world: summary,
            plugins: plugins,
            databases: scanDatabases(root: root),
            stateFiles: scanState(pluginsDirectory: pluginsDirectory, worldID: world.worldID),
            problems: problems,
            mapImages: scanMapImages(pluginsDirectory: pluginsDirectory),
            searchAndDestroy: scanSearchAndDestroy(root: root)
        )
    }

    /// The install's own Search & Destroy folder (the one holding
    /// `Search_and_Destroy.xml`), or nil. Skips the copies the user doesn't
    /// run (`Search-and-Destroy-V2`, WinkleGold, backups) — same rule as the
    /// database scan.
    static func scanSearchAndDestroy(root: URL) -> ImportManifest.SearchAndDestroyEntry? {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }
        let skip = ["search-and-destroy-v2", "winklegold", " - copy", "backup"]
        for case let url as URL in walker {
            guard url.lastPathComponent == "Search_and_Destroy.xml" else { continue }
            let lower = url.path.lowercased()
            guard !skip.contains(where: lower.contains) else { continue }
            return ImportManifest.SearchAndDestroyEntry(directory: url.deletingLastPathComponent())
        }
        return nil
    }

    /// The map background textures the GMCP mapper tiles
    /// (`worlds/plugins/images/*.png|jpg|…`), or nil when the folder is absent
    /// or holds no images. Imported into `~/Documents/Proteles/MapImages/`.
    static func scanMapImages(pluginsDirectory: URL) -> ImportManifest.MapImagesEntry? {
        let directory = pluginsDirectory.appendingPathComponent("images")
        let extensions: Set = ["png", "jpg", "jpeg", "gif", "bmp"]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }
        let count = items.count { extensions.contains($0.pathExtension.lowercased()) }
        guard count > 0 else { return nil }
        return ImportManifest.MapImagesEntry(directory: directory, count: count)
    }

    /// Find + type every `.db` under the install, skipping duplicates/backups and
    /// MUSHclient-internal databases.
    static func scanDatabases(root: URL) -> [ImportManifest.DatabaseEntry] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }

        var entries: [ImportManifest.DatabaseEntry] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "db" {
            guard let typed = databaseKind(for: url) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entries.append(.init(
                url: url,
                kind: typed.kind,
                character: typed.character,
                byteSize: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? .distantPast
            ))
        }
        return liveSingletons(entries, root: root).sorted { $0.url.path < $1.url.path }
    }

    /// Reduce the mapper, S&D, and leveldb databases to their single live copy.
    ///
    /// Mapper + S&D are the player's active databases at the MUSHclient install
    /// **top level** (`<root>/Aardwolf.db`, `<root>/SnDdb.db`). Other copies — under
    /// `worlds/plugins/…`, a `Search-and-Destroy-V2/` folder, ad-hoc merge/backup
    /// dirs — are not the live ones, and byte size is a bad proxy (a fragmented or
    /// extra-indexed file can be larger yet have fewer rooms). So just take the
    /// top-level copy; no size/room guessing. (Defensive fallback: the largest, if
    /// somehow none sits at root.) leveldb is a plugin DB (never at the root), so
    /// keep its largest non-empty copy. Per-character dinv DBs are all kept.
    static func liveSingletons(
        _ entries: [ImportManifest.DatabaseEntry],
        root: URL
    ) -> [ImportManifest.DatabaseEntry] {
        let rootPath = root.standardizedFileURL.path
        func atRoot(_ entry: ImportManifest.DatabaseEntry) -> Bool {
            entry.url.deletingLastPathComponent().standardizedFileURL.path == rootPath
        }
        func largest(_ items: [ImportManifest.DatabaseEntry]) -> ImportManifest.DatabaseEntry? {
            items.max { ($0.byteSize, $0.modified) < ($1.byteSize, $1.modified) }
        }
        var result = entries.filter {
            $0.kind != .mapper && $0.kind != .searchAndDestroy && $0.kind != .leveldb
        }
        for kind in [ImportManifest.DatabaseKind.mapper, .searchAndDestroy] {
            let candidates = entries.filter { $0.kind == kind }
            if let chosen = candidates.first(where: atRoot) ?? largest(candidates) {
                result.append(chosen)
            }
        }
        if let live = largest(entries.filter { $0.kind == .leveldb }) {
            result.append(live)
        }
        return result
    }

    /// Parse the `{worldID}-{pluginID}-state.xml` files under `state/`.
    static func scanState(
        pluginsDirectory: URL,
        worldID: String
    ) -> [ImportManifest.StateFile] {
        let stateDirectory = pluginsDirectory.appendingPathComponent("state")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: stateDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        var states: [ImportManifest.StateFile] = []
        for url in items where url.lastPathComponent.hasSuffix("-state.xml") {
            guard let pluginID = MUSHclientStateFile.pluginID(
                fromFilename: url.lastPathComponent, worldID: worldID
            ), let data = try? Data(contentsOf: url) else { continue }
            states.append(.init(pluginID: pluginID, variables: MUSHclientStateFile.parseVariables(data)))
        }
        return states.sorted { $0.pluginID < $1.pluginID }
    }

    /// Type a `.db` by name + path, or `nil` to skip (duplicate / backup /
    /// MUSHclient-internal / the `-V2`/`WinkleGold` copies the user doesn't run).
    internal static func databaseKind(
        for url: URL
    ) -> (kind: ImportManifest.DatabaseKind, character: String?)? {
        let lower = url.path.lowercased()
        // Skip the copies the user doesn't run: S&D V2, WinkleGold, "- Copy",
        // and any backup directory (e.g. `db_backups/`, `…/backup/`).
        let skip = ["search-and-destroy-v2", "winklegold", " - copy", "backup"]
        if skip.contains(where: lower.contains) { return nil }

        switch url.lastPathComponent {
        case "Aardwolf.db": return (.mapper, nil)
        case "SnDdb.db": return (.searchAndDestroy, nil)
        case "leveldb.db": return (.leveldb, nil)
        case "dinv.db":
            // …/state/dinv-<id>/<character>/dinv.db
            return (.dinv, url.deletingLastPathComponent().lastPathComponent)
        default:
            // A db in a plugin's own state subdir is plugin-owned data — it
            // travels WITH its plugin (PluginEntry.dataFiles), not as a standalone
            // database choice, so skip it here.
            if lower.contains("/plugins/state/") { return nil }
            return (.unknown, nil)
        }
    }
}

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
            problems: problems
        )
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
        return liveSingletons(entries).sorted { $0.url.path < $1.url.path }
    }

    /// Mapper, S&D, and leveldb are single live databases — when an install holds
    /// several copies (e.g. `plugins/leveldb/` + `plugins/state/leveldb/`), keep
    /// only the **largest** (most accumulated data; tiebreak most-recently
    /// modified) — the active one. Largest-first, not newest-first, so a freshly
    /// dropped *empty* copy can never beat the real db it'd otherwise out-date.
    /// Per-character dinv DBs are all kept.
    static func liveSingletons(
        _ entries: [ImportManifest.DatabaseEntry]
    ) -> [ImportManifest.DatabaseEntry] {
        let singletons: Set<ImportManifest.DatabaseKind> = [.mapper, .searchAndDestroy, .leveldb]
        var result = entries.filter { !singletons.contains($0.kind) }
        for kind in singletons {
            let live = entries.filter { $0.kind == kind }
                .max { ($0.byteSize, $0.modified) < ($1.byteSize, $1.modified) }
            if let live { result.append(live) }
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

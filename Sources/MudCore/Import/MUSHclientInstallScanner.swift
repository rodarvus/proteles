import Foundation

/// Scans a MUSHclient install (the directory containing `worlds/`) and the
/// parsed world file into an ``ImportManifest`` — resolving each enabled plugin
/// include to its files on disk and classifying it. Pure (filesystem read only);
/// no writing, no app state. Databases + plugin state are folded in by a later
/// pass.
public enum MUSHclientInstallScanner {
    /// Resolve + classify the world's enabled plugin includes.
    ///
    /// - Parameter pluginsDirectory: the install's `worlds/plugins` directory
    ///   (includes are relative to it; Windows `\` separators are normalised).
    public static func scanPlugins(
        world: MUSHclientWorldFile,
        pluginsDirectory: URL
    ) -> (plugins: [ImportManifest.PluginEntry], problems: [ImportManifest.Problem]) {
        var plugins: [ImportManifest.PluginEntry] = []
        var problems: [ImportManifest.Problem] = []

        for include in world.pluginIncludes {
            let relative = include.replacingOccurrences(of: "\\", with: "/")
            let url = pluginsDirectory.appendingPathComponent(relative)
            let data = try? Data(contentsOf: url)
            let parsed = data.flatMap { try? MUSHclientPluginLoader.parse($0) }
            let resolved = entry(
                include: include,
                parsed: parsed,
                url: data == nil ? nil : url,
                pluginsDirectory: pluginsDirectory
            )
            plugins.append(resolved)

            if data == nil {
                problems.append(.init(item: include, reason: "Plugin file not found (\(relative))"))
            } else if parsed == nil, resolved.classification != .package {
                // A parse failure only matters for a plugin we'd act on — a
                // package plugin is skipped (classified by filename), so ignore it.
                problems.append(.init(item: include, reason: "Could not parse plugin XML"))
            }
        }
        return (plugins, problems)
    }

    /// Build a classified entry. A plugin nested in a subdirectory of
    /// `pluginsDirectory` is multi-file (copy the whole subdir); one directly in
    /// it is a single `.xml`.
    private static func entry(
        include: String,
        parsed: MUSHclientPlugin?,
        url: URL?,
        pluginsDirectory: URL
    ) -> ImportManifest.PluginEntry {
        let filename = include.replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/").last ?? include

        var isMultiFile = false
        var copyRoot: URL?
        if let url {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            isMultiFile = parent != pluginsDirectory.standardizedFileURL
            copyRoot = isMultiFile ? parent : url
        }

        let referenced = codeReferencedFiles(
            pluginData: url.flatMap { try? Data(contentsOf: $0) },
            pluginsDirectory: pluginsDirectory
        )
        var dataFiles = dataFiles(forPluginID: parsed?.id, pluginsDirectory: pluginsDirectory)
        dataFiles.append(contentsOf: referenced.perCharacter)

        // Same compatibility due-diligence as the manual "add a plugin" flow:
        // analyze against the `.lua` files that travel with the plugin (its dir +
        // code-referenced sidecars); `analyze` already knows Proteles' built-ins.
        let available = availableLua(copyRoot: copyRoot, isMultiFile: isMultiFile)
            .union(referenced.pluginDirectory.map { $0.lastPathComponent.lowercased() })
        let report = parsed.map { PluginImporter.analyze($0, availableFiles: available) }

        return .init(
            include: include,
            filename: filename,
            pluginID: parsed?.id,
            name: parsed?.name,
            resolvedPath: url,
            copyRoot: copyRoot,
            isMultiFile: isMultiFile,
            classification: classify(id: parsed?.id, filename: filename),
            dataFiles: dataFiles,
            pluginDirSidecars: referenced.pluginDirectory,
            report: report
        )
    }

    /// Lowercased `.lua` basenames that travel with the plugin (the files in its
    /// own multi-file directory), so `analyze` doesn't warn about files it ships.
    private static func availableLua(copyRoot: URL?, isMultiFile: Bool) -> Set<String> {
        guard isMultiFile, let dir = copyRoot,
              let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var files: Set<String> = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "lua" {
            files.insert(url.lastPathComponent.lowercased())
        }
        return files
    }

    /// Module basenames Proteles already provides (clean-room) for `require`/
    /// `dofile`. A plugin's own GPL copy of one of these must **not** be copied
    /// into its folder: doing so shadows the working built-in and drags in
    /// package globals we don't supply (e.g. the GPL `aardwolf_colors.lua` needs
    /// `extended_colours`), aborting the plugin's load. They resolve via the
    /// shim's bundled modules instead. Mirrors `LuaRuntime.standardHelpers` +
    /// the shim's extra registrations (`LuaRuntime+CompatShim`).
    private static let providedModuleBasenames: Set<String> = Set(LuaRuntime.standardHelpers.keys)
        .union(["wait", "check", "async", "string_split", "checkplugin", "aard_requirements"])

    /// Scan a plugin's source for data files it reads relative to `GetInfo(n)`
    /// (e.g. `GetInfo(56) .. "messages_to_gag.txt"`). Resolves the named file
    /// against the install (root / world / plugins dir). `56/60/64` → the plugin's
    /// own dir; `66/67/85` → the per-character data dir. Files Proteles already
    /// provides as modules are skipped (see ``providedModuleBasenames``).
    private static func codeReferencedFiles(
        pluginData: Data?,
        pluginsDirectory: URL
    ) -> (pluginDirectory: [URL], perCharacter: [URL]) {
        guard let pluginData,
              let text = String(data: pluginData, encoding: .utf8)
              ?? String(data: pluginData, encoding: .isoLatin1) else { return ([], []) }
        let worldDirectory = pluginsDirectory.deletingLastPathComponent()
        let installRoot = worldDirectory.deletingLastPathComponent()
        let searchRoots = [installRoot, worldDirectory, pluginsDirectory]
        let pattern = #"GetInfo\s*\(\s*(\d+)\s*\)\s*\.\.\s*["']([^"'/\\]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], []) }

        var pluginDirectory: Set<URL> = []
        var perCharacter: Set<URL> = []
        let string = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let code = Int(string.substring(with: match.range(at: 1))) ?? 0
            let name = string.substring(with: match.range(at: 2))
            // Don't bring a plugin's copy of a module we already provide — it
            // would shadow our clean-room build and pull in package globals.
            if providedModuleBasenames.contains((name as NSString).deletingPathExtension) { continue }
            guard let file = searchRoots.lazy.map({ $0.appendingPathComponent(name) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            switch code {
            case 56, 60, 64: pluginDirectory.insert(file)
            case 66, 67, 85: perCharacter.insert(file)
            default: continue
            }
        }
        return (pluginDirectory.sorted { $0.path < $1.path }, perCharacter.sorted { $0.path < $1.path })
    }

    /// A plugin's own `.db` files, found under its `state/<name>-<id>/` directory
    /// (keyed by the plugin id suffix). These travel with the plugin on import.
    private static func dataFiles(forPluginID id: String?, pluginsDirectory: URL) -> [URL] {
        guard let id, !id.isEmpty else { return [] }
        let fileManager = FileManager.default
        let stateDirectory = pluginsDirectory.appendingPathComponent("state")
        guard let subdirectories = try? fileManager.contentsOfDirectory(
            at: stateDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        var files: [URL] = []
        for directory in subdirectories where directory.lastPathComponent.hasSuffix(id) {
            guard let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let file as URL in walker where file.pathExtension.lowercased() == "db" {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func classify(id: String?, filename: String) -> ImportManifest.Classification {
        if PackagePluginCatalog.contains(id: id, filename: filename) { return .package }
        if BundledPluginCatalog.contains(id: id) { return .bundled }
        return .offer
    }
}

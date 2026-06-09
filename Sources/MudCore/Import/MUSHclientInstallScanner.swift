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

        return .init(
            include: include,
            filename: filename,
            pluginID: parsed?.id,
            name: parsed?.name,
            resolvedPath: url,
            copyRoot: copyRoot,
            isMultiFile: isMultiFile,
            classification: classify(id: parsed?.id, filename: filename)
        )
    }

    private static func classify(id: String?, filename: String) -> ImportManifest.Classification {
        if PackagePluginCatalog.contains(id: id, filename: filename) { return .package }
        if BundledPluginCatalog.contains(id: id) { return .bundled }
        return .offer
    }
}

import Foundation

/// Loading MUSHclient plugins into the live ``ScriptEngine`` — both the
/// world's imported plugins (copied into the per-profile plugins folder) and
/// its **personal** plugins (referenced in place from the user's own disk).
/// Split out of ``SessionController`` so the scripting extension stays within
/// the file-length budget.
public extension SessionController {
    /// Discover and load every MUSHclient `.xml` plugin in `directory` into the
    /// live engine: parse each, scope it with a ``PluginContext`` rooted at the
    /// directory (so `require`/`dofile`/`GetInfo` resolve there), run it (firing
    /// `OnPluginInstall`), and apply the resulting effects. Call after
    /// ``loadScripts(_:)`` (which resets the engines) and before connecting.
    /// No-op without a script engine or plugins.
    func loadPlugins(fromDirectory directory: URL) async {
        guard let scriptEngine else { return }
        loadedPluginsDirectory = directory
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let xmlFiles = entries
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !xmlFiles.isEmpty else { return }

        // Plugins resolve their own files (and dofile targets) here.
        await scriptEngine.setModuleSearchPaths([directory.path])
        for url in xmlFiles {
            guard let data = try? Data(contentsOf: url),
                  let plugin = try? MUSHclientPluginLoader.parse(data)
            else { continue }
            // GetInfo(66)/(67) → the world-data dir (trailing slash so
            // `GetInfo(66)..WorldName()..".db"` resolves to the mapper DB).
            let worldDir = worldDataDirectory.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
            let context = PluginContext(
                pluginID: plugin.id,
                pluginName: plugin.name,
                pluginDirectory: directory.path,
                worldDirectory: worldDir,
                appDirectory: worldDir
            )
            await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        }
        // OnPluginInstall may have set variables; persist them.
        await persistVariablesIfDirty()
        // Plugins may have registered timers.
        restartTimerLoop()
    }

    /// Load the world's **personal** plugins — referenced in place from the
    /// user's own disk (never copied into app-support), each resolving its
    /// `dofile`/`require` modules from its own folder. Call after
    /// ``loadPlugins(fromDirectory:)`` so the module search path is the union of
    /// the imported-plugins dir + every personal plugin's folder. Disabled refs
    /// and paths that don't resolve to a plugin `.xml` are skipped.
    func loadLocalPlugins(_ references: [LocalPluginReference]) async {
        guard let scriptEngine else { return }
        let resolved = references
            .filter(\.enabled)
            .compactMap { LocalPluginStore.resolvePluginXML(at: $0.url) }
        guard !resolved.isEmpty else { return }

        var searchPaths = resolved.map { $0.deletingLastPathComponent().path }
        if let imported = loadedPluginsDirectory?.path { searchPaths.insert(imported, at: 0) }
        await scriptEngine.setModuleSearchPaths(searchPaths)

        let worldDir = worldDataDirectory.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
        for xml in resolved {
            guard let data = try? Data(contentsOf: xml),
                  let plugin = try? MUSHclientPluginLoader.parse(data)
            else { continue }
            let context = PluginContext(
                pluginID: plugin.id,
                pluginName: plugin.name,
                pluginDirectory: xml.deletingLastPathComponent().path,
                worldDirectory: worldDir,
                appDirectory: worldDir
            )
            await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        }
        await persistVariablesIfDirty()
        restartTimerLoop()
    }
}

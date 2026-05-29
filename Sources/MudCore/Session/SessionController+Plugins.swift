import Foundation

/// Loading the user's library plugins into the live ``ScriptEngine``. A library
/// plugin lives in its own self-contained directory under
/// `~/Documents/Proteles/Plugins/<name>/` (see `PluginLibrary`); this resolves
/// each enabled entry to its `.xml` + module folder and runs it through the
/// compat shim. Split out of ``SessionController`` to stay within the file-length
/// budget.
public extension SessionController {
    /// Load the plugins in the given directories (each a self-contained plugin
    /// dir, one `.xml` + its modules) into the live engine: set the module search
    /// path to the union of the directories (so `require`/`dofile`/`GetInfo`
    /// resolve), parse + run each (firing `OnPluginInstall`), and apply the
    /// effects. Records each plugin's directory for `ReloadPlugin`. Call after
    /// ``loadScripts(_:)`` (which resets the engines) and before connecting.
    /// A directory with no resolvable `.xml` is skipped. No-op without a script
    /// engine.
    func loadPlugins(directories: [URL]) async {
        guard let scriptEngine else { return }
        let resolved: [(directory: URL, xml: URL)] = directories.compactMap { directory in
            guard let xml = PluginInstaller.resolvePluginXML(at: directory) else { return nil }
            return (directory, xml)
        }
        guard !resolved.isEmpty else {
            loadedPluginDirectories = [:]
            return
        }
        await scriptEngine.setModuleSearchPaths(resolved.map(\.directory.path))

        // GetInfo(66)/(67) → the world-data dir (trailing slash so
        // `GetInfo(66)..WorldName()..".db"` resolves to a plugin's DB).
        let worldDir = worldDataDirectory.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
        var directories: [String: URL] = [:]
        for (directory, xml) in resolved {
            guard let data = try? Data(contentsOf: xml),
                  let plugin = try? MUSHclientPluginLoader.parse(data)
            else { continue }
            directories[plugin.id] = directory
            let context = PluginContext(
                pluginID: plugin.id,
                pluginName: plugin.name,
                pluginDirectory: Self.directoryPath(directory),
                worldDirectory: worldDir,
                appDirectory: worldDir
            )
            await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        }
        loadedPluginDirectories = directories
        // OnPluginInstall may have set variables; persist them.
        await persistVariablesIfDirty()
        // Plugins may have registered timers.
        restartTimerLoop()
    }

    /// A directory path with a guaranteed trailing slash. MUSHclient's
    /// `GetInfo(60)` / `GetPluginInfo(id, 20)` return the plugin directory with a
    /// trailing separator, and plugins concatenate file names onto it
    /// (`GetPluginInfo(id, 20) .. "x_db.lua"`); without the slash that mangles
    /// into `…/<folder><file>` (e.g. `…/plugins/myplugmyplug_db.lua`).
    static func directoryPath(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? path : path + "/"
    }
}

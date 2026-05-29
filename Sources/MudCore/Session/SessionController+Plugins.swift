import Foundation

/// Loading the user's library plugins into the live ``ScriptEngine``. A library
/// plugin lives in its own self-contained directory under
/// `~/Documents/Proteles/Plugins/<name>/` (see `PluginLibrary`); this resolves
/// each enabled entry to its `.xml` + module folder and runs it through the
/// compat shim. Split out of ``SessionController`` to stay within the file-length
/// budget.
public extension SessionController {
    /// Load the plugins in the given directories (each a self-contained plugin
    /// dir, one `.xml` + its modules) into the live engine for character
    /// `profile`: set the module search path to the union of the directories (so
    /// `require`/`dofile`/`GetInfo` resolve), parse + run each (firing
    /// `OnPluginInstall`), and apply the effects. Each plugin's `GetInfo(66)`
    /// (`worldDirectory`) is its **own** per-character data dir
    /// (`<plugin>/data/<profile>/`), so its SQLite DB + state stay with it (the
    /// engine-wide lsqlite3 sandbox root spans the whole `~/Documents/Proteles`
    /// tree). Records each plugin's code + data dirs for `ReloadPlugin`. Call
    /// after ``loadScripts(_:)`` and before connecting. A directory with no
    /// resolvable `.xml` is skipped. No-op without a script engine. `character`
    /// is the readable per-character data-dir key (the character name).
    func loadPlugins(directories: [URL], character: String) async {
        guard let scriptEngine else { return }
        let resolved: [(directory: URL, xml: URL)] = directories.compactMap { directory in
            guard let xml = PluginInstaller.resolvePluginXML(at: directory) else { return nil }
            return (directory, xml)
        }
        guard !resolved.isEmpty else {
            loadedPluginPaths = [:]
            return
        }
        await scriptEngine.setModuleSearchPaths(resolved.map(\.directory.path))

        var paths: [String: (code: URL, data: URL)] = [:]
        for (directory, xml) in resolved {
            guard let data = try? Data(contentsOf: xml),
                  let plugin = try? MUSHclientPluginLoader.parse(data)
            else { continue }
            let dataDir = Self.pluginDataDirectory(for: directory, character: character)
            let dataPath = Self.directoryPath(dataDir)
            paths[plugin.id] = (code: directory, data: dataDir)
            // `GetInfo(66)` (world dir) AND `GetInfo(85)` (state files dir) point
            // at the plugin's own data dir, so a plugin that builds its DB/state
            // path from either finds it there (e.g. a DB-backed plugin's state).
            let context = PluginContext(
                pluginID: plugin.id,
                pluginName: plugin.name,
                pluginDirectory: Self.directoryPath(directory),
                worldDirectory: dataPath,
                appDirectory: dataPath,
                stateDirectory: dataPath
            )
            await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        }
        loadedPluginPaths = paths
        // OnPluginInstall may have set variables; persist them.
        await persistVariablesIfDirty()
        // Plugins may have registered timers.
        restartTimerLoop()
    }

    /// A plugin's per-character data dir, `<plugin>/data/<character>/` (created),
    /// where its DB + state live (`GetInfo(66)`/`GetInfo(85)`).
    static func pluginDataDirectory(for codeDirectory: URL, character: String) -> URL {
        let dataDir = codeDirectory
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(character, isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        return dataDir
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

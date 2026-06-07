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

    /// Enable a single library plugin **hermetically** — load just it, leaving
    /// every other plugin + the mapper/S&D host running untouched (MUSHclient
    /// parity; not the old full-world-reload). When connected and **in-game**
    /// (plugins live), it loads now and fires its `OnPluginConnect`; when
    /// connected but pre-in-game it's added to the armed set (D-74) to load at
    /// the in-game signal. When disconnected this is a no-op — the library
    /// registry is the source of truth and the next connect re-arms from it.
    func enablePlugin(directory: URL, character: String) async {
        guard connection != nil else { return }
        if pluginsLoaded {
            await loadOnePlugin(directory: directory, character: character, fireConnect: seenCharInGame)
            await rearmTimerLoopIfScriptScheduled()
            await persistVariablesIfDirty()
        } else {
            if !pendingInitialPluginDirectories.contains(directory) {
                pendingInitialPluginDirectories.append(directory)
            }
            pendingInitialPluginCharacter = character
        }
    }

    /// Disable a single library plugin hermetically — unload just it (drops its
    /// triggers/aliases/timers + Lua env) and recompute the module search path
    /// from the remaining loaded plugins. No-op while disconnected (the registry
    /// + next connect handle it). `directory` (if known) is dropped from the
    /// armed set so a not-yet-in-game session won't load it.
    func disablePlugin(id: String, directory: URL?) async {
        guard connection != nil else { return }
        if let directory { pendingInitialPluginDirectories.removeAll { $0 == directory } }
        guard let scriptEngine, loadedPluginPaths[id] != nil else { return }
        await scriptEngine.unloadPlugin(id)
        loadedPluginPaths[id] = nil
        await scriptEngine.setModuleSearchPaths(loadedPluginPaths.values.map(\.code.path))
    }

    /// Load one library plugin into the live engine (the shared core of the bulk
    /// ``loadPlugins(directories:character:)`` and the hermetic ``enablePlugin``).
    /// Appends to ``loadedPluginPaths`` and re-derives the module search path as
    /// the union of all loaded library plugins' dirs. `fireConnect` runs its
    /// `OnPluginConnect` (a mid-session enable that's already in-game).
    private func loadOnePlugin(directory: URL, character: String, fireConnect: Bool) async {
        guard let scriptEngine,
              let xml = PluginInstaller.resolvePluginXML(at: directory),
              let data = try? Data(contentsOf: xml),
              let plugin = try? MUSHclientPluginLoader.parse(data)
        else { return }
        let dataDir = Self.pluginDataDirectory(for: directory, character: character)
        let dataPath = Self.directoryPath(dataDir)
        // Surface the flat per-character Databases dir for proteles.databaseDir() (#44).
        if let dbPath = databasesDirectoryPath(forCharacter: character) {
            await scriptEngine.setDatabasesDirectory(dbPath)
        }
        loadedPluginPaths[plugin.id] = (code: directory, data: dataDir)
        await scriptEngine.setModuleSearchPaths(loadedPluginPaths.values.map { Self.directoryPath($0.code) })
        let context = PluginContext(
            pluginID: plugin.id,
            pluginName: plugin.name,
            pluginDirectory: Self.directoryPath(directory),
            worldDirectory: dataPath,
            appDirectory: dataPath,
            stateDirectory: dataPath
        )
        await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        if fireConnect { await applyScriptEffects(scriptEngine.connectPlugin(plugin.id)) }
    }

    /// The flat per-character `Databases/<character>/` path (trailing slash)
    /// surfaced to plugins via `proteles.databaseDir()` (#44), or `nil` for an
    /// empty/unknown character.
    func databasesDirectoryPath(forCharacter character: String?) -> String? {
        guard let character, !character.isEmpty,
              let dir = try? ProtelesPaths.pluginDatabasesDirectory(character: character)
        else { return nil }
        return Self.directoryPath(dir)
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

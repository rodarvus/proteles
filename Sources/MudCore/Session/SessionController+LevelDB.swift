import Foundation

/// Loads the vendored **leveldb** leveling database (run verbatim through the
/// compat shim — see `Resources/leveldb`).
public extension SessionController {
    /// Load leveldb eagerly (unlike dinv): its `OnPluginInstall` opens its SQLite
    /// DB + reads cached GMCP, and collection is via declarative triggers (no
    /// char.base-while-active gating). Called from the world-load path after the
    /// script reset. `dataDirectory` is its `GetInfo(60)` home; leveldb writes
    /// `state/leveldb/leveldb.db` under it. No-op without a script engine / XML.
    func loadBundledLevelDB(dataDirectory: String) async {
        guard let scriptEngine, let xml = LevelDBAssets.pluginXML,
              let plugin = try? MUSHclientPluginLoader.parse(xml: xml)
        else { return }
        let suffixed = dataDirectory.hasSuffix("/") ? dataDirectory : dataDirectory + "/"
        let context = PluginContext(
            pluginID: LevelDBAssets.pluginID,
            pluginName: "leveldb",
            pluginDirectory: suffixed,
            worldDirectory: suffixed,
            appDirectory: suffixed,
            stateDirectory: suffixed
        )
        await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        await persistVariablesIfDirty()
        restartTimerLoop()
    }
}

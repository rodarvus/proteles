import Foundation

/// dinv (the bundled inventory plugin) load flow. Split out of
/// `SessionController+Scripting` to keep that file within the size budget.
public extension SessionController {
    /// Load dinv now that the character is active (called from the GMCP path).
    /// After install, replay a `char.base` broadcast so dinv — freshly loaded
    /// with its init flag clear — catches it while active and initializes.
    func loadPendingDinv() async {
        guard !dinvLoaded, let stateDirectory = pendingDinvStateDirectory,
              let scriptEngine, let xml = DinvAssets.pluginXML,
              let plugin = try? MUSHclientPluginLoader.parse(xml: xml)
        else { return }
        dinvLoaded = true
        await scriptEngine.registerModules(DinvAssets.modules)
        // Flat per-character Databases/<character>/ for proteles.databaseDir() (#44).
        if let dbPath = databasesDirectoryPath(forCharacter: pendingInitialPluginCharacter) {
            await scriptEngine.setDatabasesDirectory(dbPath)
        }
        let suffixed = stateDirectory.hasSuffix("/") ? stateDirectory : stateDirectory + "/"
        let context = PluginContext(
            pluginID: DinvAssets.pluginID,
            pluginName: "dinv",
            version: "3.0102",
            pluginDirectory: suffixed,
            worldDirectory: suffixed,
            appDirectory: suffixed,
            stateDirectory: suffixed
        )
        let loadEffects = await measureSessionPhase(
            "session.dinv.load-plugin",
            events: 1,
            thresholdMS: 50
        ) {
            await scriptEngine.loadPlugin(plugin, context: context)
        }
        await applyScriptEffects(loadEffects)
        // Replay char.base so dinv — freshly loaded with its init flag clear —
        // catches it while active and runs its init chain.
        let replayEffects = await measureSessionPhase(
            "session.dinv.replay-char-base",
            events: 1,
            thresholdMS: 50
        ) {
            await scriptEngine.deliverGMCPBroadcast(package: "char.base")
        }
        await applyScriptEffects(replayEffects)
        await measureSessionPhase(
            "session.dinv.persist",
            events: 1,
            thresholdMS: 50
        ) {
            await persistVariablesIfDirty()
        }
        restartTimerLoop()
    }
}

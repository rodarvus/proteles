import Foundation

/// Plugin reload + the inbound-routing control effects (synthesized GMCP,
/// `Simulate`, `ReloadPlugin`). Split out of ``SessionController+Scripting`` to
/// keep that file within the length budget and `applyControlEffect` within the
/// complexity budget.
extension SessionController {
    /// The control effects that re-enter the inbound path (vs. the output /
    /// state effects ``applyControlEffect`` handles directly). Kept separate so
    /// the primary switch stays under the cyclomatic-complexity limit.
    func applyInboundControlEffect(_ effect: ScriptEffect) async {
        switch effect {
        case .callSearchAndDestroy(let function, let args):
            // A shim plugin's CallPlugin(<S&D id>, fn, …) → the native host.
            if let searchAndDestroy {
                await applyScriptEffects(searchAndDestroy.call(function, args: args))
                await rearmTimerLoopIfSnDScheduled()
            }
        case .searchAndDestroyState(let target, let targets, let gotoCount):
            // The S&D host's shim-readable state changed → mirror it into the
            // shim runtime, where CallPlugin(<S&D id>, "target_as_json") etc.
            // answer synchronously (the effect path can't return values).
            await scriptEngine?.setSearchAndDestroyState(
                target: target, targets: targets, gotoCount: gotoCount
            )
        case .simulate(let text):
            await reinjectSimulated(text)
        case .injectGMCP(let package, let json):
            // Feed a synthesized GMCP message through the same inbound dispatch
            // as a real packet (native GMCP handler's config-state synthesis).
            await dispatchGMCP(GMCPMessage(package: package, json: json))
        case .reloadPlugin(let id):
            await reloadPlugin(id: id)
        case .chatCapture(let text, let channel):
            // Bridge `CallPlugin(<chat-capture>, "storeFromOutside", …)` to native
            // chat (rsocial/hadar_spellup); `text` may carry Aardwolf @-codes.
            await chatStore.append(channel: channel.isEmpty ? "Capture" : channel, player: "", message: text)
        case .notify(let title, let body):
            // Script/plugin-raised notification (`Notify`/`proteles.notify`).
            notifyFromScript(title: title, body: body)
        case .button(let command):
            // Script/plugin button-bar change (#15) → forwarded to the app.
            buttonCommandsContinuation.yield(command)
        default:
            // Miniwindow scene/image updates (the miniwindow spike) — forwarded
            // to the UI stream; a no-op for any other effect.
            _ = applyMiniWindowEffect(effect)
        }
    }

    /// Reload a plugin by id (MUSHclient `ReloadPlugin`), routing by kind:
    ///
    /// - **Native (Swift) plugin** → disable then re-enable, which re-runs its
    ///   `install()` on the same registered instance (its in-memory state
    ///   survives the cycle).
    /// - **Bundled dinv** → unload it, clear the one-shot guard, and re-run the
    ///   armed-load sequence (fresh env + `OnPluginInstall` + the `char.base`
    ///   replay that kicks off init).
    /// - **On-disk MUSHclient plugin** → unload it, re-read its XML from the
    ///   active world's plugin directory, and load it fresh.
    ///
    /// The timer loop is restarted afterwards since a reload commonly
    /// (re-)registers timers.
    func reloadPlugin(id: String) async {
        guard let scriptEngine else { return }
        if await scriptEngine.isNativePlugin(id: id) {
            await applyScriptEffects(scriptEngine.setNativePluginEnabled(false, id: id))
            await applyScriptEffects(scriptEngine.setNativePluginEnabled(true, id: id))
            restartTimerLoop()
            return
        }
        await scriptEngine.unloadPlugin(id)
        if id == DinvAssets.pluginID {
            dinvLoaded = false
            await loadPendingDinv()
            return
        }
        await reloadDiskPlugin(id: id)
    }

    /// Re-read a single on-disk MUSHclient plugin (already unloaded) from its own
    /// library directory and load it fresh. No-op if the plugin's directory or a
    /// matching plugin `.xml` can't be found.
    private func reloadDiskPlugin(id: String) async {
        guard let scriptEngine,
              let paths = loadedPluginPaths[id],
              let xml = PluginInstaller.resolvePluginXML(at: paths.code),
              let data = try? Data(contentsOf: xml),
              let plugin = try? MUSHclientPluginLoader.parse(data), plugin.id == id
        else { return }
        let dataDir = Self.directoryPath(paths.data)
        let context = PluginContext(
            pluginID: plugin.id,
            pluginName: plugin.name,
            pluginDirectory: Self.directoryPath(paths.code),
            worldDirectory: dataDir,
            appDirectory: dataDir,
            stateDirectory: dataDir
        )
        await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        await persistVariablesIfDirty()
        restartTimerLoop()
    }
}

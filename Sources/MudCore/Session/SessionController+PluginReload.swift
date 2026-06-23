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
        if await applyPluginControlEffect(effect) { return }
        if applyOutwardPluginEffect(effect) { return }
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
        case .chatCapture(let text, let channel):
            // Bridge `CallPlugin(<chat-capture>, "storeFromOutside", …)` to native
            // chat (rsocial/hadar_spellup); `text` may carry Aardwolf @-codes.
            await chatStore.append(channel: channel.isEmpty ? "Capture" : channel, player: "", message: text)
        default:
            // Miniwindow scene/image updates (the miniwindow spike) — forwarded
            // to the UI stream; a no-op for any other effect.
            _ = applyMiniWindowEffect(effect)
            // Pace a wait-bearing mapper walk (`.walkWithWaits`) or release the
            // walk-deferral queue on arrival (`.walkCompleted`); no-op otherwise.
            await applyWalkEffect(effect)
        }
    }

    /// Outward plugin effects forwarded straight to the app/native layers: a
    /// user notification (`Notify`), an `OpenBrowser(url)` request (the app
    /// confirms per plugin, then opens), and a button-bar change (#15). Split
    /// into a Bool handler so ``applyInboundControlEffect`` stays within the
    /// cyclomatic-complexity budget. Returns whether handled.
    private func applyOutwardPluginEffect(_ effect: ScriptEffect) -> Bool {
        switch effect {
        case .notify(let title, let body):
            notifyFromScript(title: title, body: body)
        case .openBrowser(let url, let pluginID, let pluginName):
            openBrowserRequestsContinuation.yield(
                OpenBrowserRequest(url: url, pluginID: pluginID, pluginName: pluginName)
            )
        case .button(let command):
            buttonCommandsContinuation.yield(command)
        default:
            return false
        }
        return true
    }

    /// Plugin/connection lifecycle effects (`ReloadPlugin`/`UnloadPlugin`/
    /// `Connect`). Split into its own Bool handler so ``applyInboundControlEffect``
    /// stays within the cyclomatic-complexity budget. Returns whether handled.
    private func applyPluginControlEffect(_ effect: ScriptEffect) async -> Bool {
        switch effect {
        case .reloadPlugin(let id):
            await reloadPlugin(id: id)
        case .unloadPlugin(let id):
            // MUSHclient UnloadPlugin: drop the named shim plugin (idempotent —
            // a native/unknown id is a no-op). Apply any window-delete effects
            // the teardown returns so its miniwindows clear from the UI.
            if let scriptEngine {
                let hadLibraryPlugin = loadedPluginPaths[id] != nil
                await applyScriptEffects(scriptEngine.unloadPlugin(id))
                loadedPluginPaths[id] = nil
                await scriptEngine.setModuleSearchPaths(loadedPluginPaths.values.map(\.code.path))
                if hadLibraryPlugin {
                    await applyScriptEffects(scriptEngine.pluginListChanged())
                }
            }
        case .connect:
            await connectFromScript()
        default:
            return false
        }
        return true
    }

    /// MUSHclient `Connect`: re-open the connection if it's closed, reusing the
    /// last endpoint/autologin (the same path the reconnect loop uses). A no-op
    /// when already connected (the shim returns `eWorldOpen` without emitting
    /// this) or when there's no prior endpoint to reconnect to.
    private func connectFromScript() async {
        guard connection == nil, let endpoint = lastEndpoint else { return }
        try? await establish(to: endpoint, autologin: lastAutologinPlan, surfaceFailureState: true)
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
        // Clear the plugin's miniwindows; reloadDiskPlugin re-runs its install,
        // which recreates any it still draws.
        await applyScriptEffects(scriptEngine.unloadPlugin(id))
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
        await applyScriptEffects(scriptEngine.pluginListChanged())
        await persistVariablesIfDirty()
        restartTimerLoop()
    }
}

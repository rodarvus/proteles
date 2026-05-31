import Foundation

/// Deferred plugin activation. Rather than loading MUSHclient plugins at
/// world-load (during login + MOTD, where their init-time server probes like
/// `slist` or `cp info` fail), we **arm** the loads and run them only once the
/// character is in-game — the first `char.status` with state ≥ 3, the signal
/// dinv has always used. Activation loads the plugins (their `OnPluginInstall`)
/// once, then fires `OnPluginConnect`; a fallback timer covers a stuck login or
/// a MUD that never sends state 3.
extension SessionController {
    /// How long to wait for the in-game signal before activating anyway.
    /// Generous: Aardwolf sends an in-game `char.status` within seconds of login,
    /// so this only matters as insurance.
    static let pluginActivationFallback: Duration = .seconds(45)

    /// Record the initial plugin set to load on activation (called at world-load
    /// instead of loading immediately). Re-arming resets ``pluginsLoaded`` so a
    /// freshly-selected world reloads its plugins on the next in-game signal.
    public func armInitialPlugins(directories: [URL], character: String, levelDBDirectory: String?) {
        pendingInitialPluginDirectories = directories
        pendingInitialPluginCharacter = character
        pendingLevelDBDirectory = levelDBDirectory
        pluginsLoaded = false
    }

    /// Activate plugins for this connection: load the armed set once (their
    /// `OnPluginInstall`), then fire `OnPluginConnect`. Idempotent — driven by
    /// both the in-game signal and the fallback timer; the load runs once per
    /// world (plugins persist across reconnects), the connect once per connection.
    func activatePluginsIfNeeded() async {
        guard connection != nil, scriptEngine != nil else { return }
        pluginActivationFallbackTask?.cancel()
        pluginActivationFallbackTask = nil

        if !pluginsLoaded {
            pluginsLoaded = true
            await loadDeferredInitialPlugins()
        }
        if !pluginsConnectFired, let scriptEngine {
            pluginsConnectFired = true
            await applyScriptEffects(scriptEngine.connectPlugins())
        }
        // Loads/connect commonly arm timers + schedule probes; re-arm the loop.
        await rearmTimerLoopIfScriptScheduled()
        await persistVariablesIfDirty()
    }

    /// Run the armed initial loads: the enabled library plugins, the bundled
    /// leveldb, and the armed dinv. Each is guarded/idempotent on its own.
    private func loadDeferredInitialPlugins() async {
        if let character = pendingInitialPluginCharacter, !pendingInitialPluginDirectories.isEmpty {
            await loadPlugins(directories: pendingInitialPluginDirectories, character: character)
        }
        if let levelDBDirectory = pendingLevelDBDirectory {
            await loadBundledLevelDB(dataDirectory: levelDBDirectory)
        }
        // NOTE: dinv is intentionally NOT loaded here. Its init is a fragile
        // one-shot — it runs `inv.init.atActive()` only on the *first* char.base
        // broadcast it sees, and only if the state is active at that instant
        // (else it flips its "initialized" flag and never retries). Loading it
        // inside this simultaneous batch (alongside ~15 other plugins, all
        // sending probes) raced its char.base handling and left it uninitialized
        // (the user had to `dinv reload`). So dinv keeps its own dedicated
        // arming (`armedDinvShouldLoad` → `loadPendingDinv` in `dispatchGMCP`),
        // which already loads it on the in-game char.status with clean timing.
    }

    /// Arm the fallback that activates plugins if no in-game `char.status`
    /// arrives in time. Replaces any previous timer.
    func schedulePluginActivationFallback() {
        pluginActivationFallbackTask?.cancel()
        pluginActivationFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pluginActivationFallback)
            guard !Task.isCancelled else { return }
            await self?.activatePluginsIfNeeded()
        }
    }
}

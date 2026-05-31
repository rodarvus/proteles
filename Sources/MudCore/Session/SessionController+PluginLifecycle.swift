import Foundation

/// Deferred plugin `OnPluginConnect`: rather than firing it on the raw socket
/// connect (during login + MOTD, where a plugin's server probes like `slist` or
/// `cp info` fail), we hold it until the character is actually **in-game** — the
/// first `char.status` with state ≥ 3, the same signal the D-70 broadcast gate
/// uses. A fallback timer fires it anyway if that signal never arrives, so a
/// stuck login (or a MUD that doesn't send state 3) can't strand plugins.
extension SessionController {
    /// How long to wait for the in-game signal before firing `OnPluginConnect`
    /// anyway. Generous: Aardwolf reliably sends an in-game `char.status` within
    /// seconds of login, so this only matters as insurance.
    static let pluginConnectFallback: Duration = .seconds(45)

    /// Fire `OnPluginConnect` on every loaded plugin exactly once per connection.
    /// Idempotent — called by both the in-game signal and the fallback timer;
    /// whichever wins, the other becomes a no-op.
    func firePluginConnectIfNeeded() async {
        guard !pluginsConnectFired, connection != nil, let scriptEngine else { return }
        pluginsConnectFired = true
        pluginConnectFallbackTask?.cancel()
        pluginConnectFallbackTask = nil
        await applyScriptEffects(scriptEngine.connectPlugins())
        // OnPluginConnect commonly arms timers / schedules probes; re-arm the
        // loop so they fire when idle (same as the broadcast/command paths).
        await rearmTimerLoopIfScriptScheduled()
        await persistVariablesIfDirty()
    }

    /// Arm the fallback that fires the deferred `OnPluginConnect` if no in-game
    /// `char.status` arrives in time. Replaces any previous timer.
    func schedulePluginConnectFallback() {
        pluginConnectFallbackTask?.cancel()
        pluginConnectFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pluginConnectFallback)
            guard !Task.isCancelled else { return }
            await self?.firePluginConnectIfNeeded()
        }
    }
}

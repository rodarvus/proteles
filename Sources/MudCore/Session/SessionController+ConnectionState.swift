import Foundation

/// Connection-state transitions: publishing the deduplicated state stream,
/// driving the timer/keepalive loop with the connection, and firing the plugin
/// lifecycle callbacks (disconnect now; connect is deferred to the in-game
/// signal — see ``SessionController/firePluginConnectIfNeeded()``). Split out of
/// the core actor file to keep it within the file-length budget.
extension SessionController {
    /// Update the mirrored state and republish it (deduplicated so the durable
    /// stream never emits the same state twice in a row).
    func updateState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        connectionStatesContinuation.yield(newState)
        syncTimerLoop(to: newState)
        // Keep S&D's `IsConnected()` in sync (gates its init bootstrap; its
        // init hook auto-detects an already-running campaign).
        if let searchAndDestroy {
            Task { await searchAndDestroy.setConnected(newState == .connected) }
        }
        // Keep scripts' `isConnected` in sync + drive plugin lifecycle callbacks.
        if let scriptEngine {
            Task { [weak self] in
                await scriptEngine.setConnected(newState == .connected)
                // MUSHclient plugin load + OnPluginConnect are deferred to the
                // in-game signal (see activatePluginsIfNeeded) — NOT run on the
                // raw connect, so plugins don't probe the server during
                // login/MOTD. Native plugins still connect now (their connect is
                // login-safe, e.g. AsciiMap just enables an out-of-band telnet
                // option).
                var effects: [ScriptEffect] = switch newState {
                case .disconnected: await scriptEngine.disconnectPlugins()
                default: []
                }
                if newState == .connected {
                    await effects.append(contentsOf: scriptEngine.connectNativePlugins())
                    await self?.schedulePluginActivationFallback()
                }
                if !effects.isEmpty { await self?.applyScriptEffects(effects) }
                await self?.persistVariablesIfDirty()
            }
        }
    }

    /// Drive the timer loop with the connection: start on connect (re-arms
    /// timers on reconnect), stop on disconnect (teardownSession also cancels it).
    func syncTimerLoop(to newState: State) {
        switch newState {
        case .connected:
            restartTimerLoop()
            lastOutboundActivity = Date() // a fresh connect counts as activity
            startKeepAlive()
        case .disconnected:
            timerTask?.cancel(); timerTask = nil
            keepAliveTask?.cancel(); keepAliveTask = nil
        default: break
        }
    }
}

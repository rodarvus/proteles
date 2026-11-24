import Foundation

/// `OnPluginSend`, MUSHclient's send hook, offered every command before it
/// goes to the MUD.
extension SessionController {
    /// True on the call chain of a send that is in the hook, so a send the
    /// hook's effects make (dinv re-sending a line it held or bypassed) goes
    /// straight to the MUD instead of back into the hook: MUSHclient's
    /// `m_bPluginProcessingSend`. A task-local, not a flag on the session:
    /// a flag let a send from another task, made while one was in the hook,
    /// skip it too (session-20261124-074839, 08:05:01: a second walk's
    /// markers skipped dinv's portal-hop hold and reached the MUD out of
    /// order).
    @TaskLocal static var insidePluginSend = false

    /// Send a command, first offering it to plugins' `OnPluginSend`. A plugin
    /// blocking it suppresses the raw send — it handled it (dinv holds it, or
    /// strips its `DINV_BYPASS` prefix and re-sends). One send is in the hook
    /// at a time; the rest wait in order. No script engine → straight to the
    /// MUD.
    func sendCommandThroughPlugins(_ command: String) async {
        guard let scriptEngine, !Self.insidePluginSend else {
            try? await sendLine(command)
            return
        }
        await enterPluginSend()
        let blocked = await Self.$insidePluginSend.withValue(true) {
            let (blocked, effects) = await scriptEngine.fireOnPluginSend(command)
            if !effects.isEmpty { await applyScriptEffects(effects) }
            return blocked
        }
        if !blocked { try? await sendLine(command) }
        leavePluginSend()
    }

    private func enterPluginSend() async {
        guard pluginProcessingSend else {
            pluginProcessingSend = true
            return
        }
        await withCheckedContinuation { pluginSendWaiters.append($0) }
    }

    /// Hand the hook to the next waiting send, or free it.
    private func leavePluginSend() {
        guard !pluginSendWaiters.isEmpty else {
            pluginProcessingSend = false
            return
        }
        pluginSendWaiters.removeFirst().resume()
    }
}

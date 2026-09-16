import Foundation

extension ScriptEngine {
    /// Snapshot IDs, keeping their actions in the engine until the host is
    /// ready to run them. An unload may remove pending IDs between firings.
    func dueTimerIDs(at now: Date) -> [UUID] {
        suspended ? [] : timers.dueIDs(at: now)
    }

    /// Run one still-due timer. The session must apply the returned effects
    /// before asking for the next timer, particularly ReloadPlugin/UnloadPlugin.
    func fireTimer(id: UUID, at now: Date) async -> [ScriptEffect] {
        guard !suspended, let firing = timers.fire(id: id, at: now) else { return [] }
        var effects: [ScriptEffect] = []
        if let send = firing.send, !send.isEmpty {
            effects.append(.send(send))
        }
        if let script = firing.script {
            await effects.append(contentsOf: runOwnedScript(
                script, owner: automationOwners[id], matches: [], named: [:]
            ))
        }
        return effects
    }
}

import MudCore

/// Bulk enable/disable by group (#35). Triggers, aliases, and timers carry an
/// optional `group` precisely for this (the model field predates the UI);
/// MUSHclient exposes it as `EnableTriggerGroup` & co., and imported sets
/// lean on it heavily — a "hunt" group is toggled as one thing, not item by
/// item. Each change goes through the same store + live-session path as a
/// single edit, so it persists *and* takes effect immediately.
public extension ScriptsModel {
    func setTriggerGroupEnabled(_ group: String, _ enabled: Bool) async {
        for trigger in triggers where trigger.group == group && trigger.enabled != enabled {
            var updated = trigger
            updated.enabled = enabled
            try? await store?.updateTrigger(updated)
            await session.scriptEngine?.updateTrigger(updated)
        }
        await refresh()
    }

    func setAliasGroupEnabled(_ group: String, _ enabled: Bool) async {
        for alias in aliases where alias.group == group && alias.enabled != enabled {
            var updated = alias
            updated.enabled = enabled
            try? await store?.updateAlias(updated)
            await session.scriptEngine?.updateAlias(updated)
        }
        await refresh()
    }

    func setTimerGroupEnabled(_ group: String, _ enabled: Bool) async {
        for timer in timers where timer.group == group && timer.enabled != enabled {
            var updated = timer
            updated.enabled = enabled
            try? await store?.updateTimer(updated)
            await session.updateTimer(updated)
        }
        await refresh()
    }
}

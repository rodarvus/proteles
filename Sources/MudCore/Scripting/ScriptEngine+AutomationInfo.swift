import Foundation

/// Projects the live trigger/alias/timer engines into the read-only
/// ``AutomationSnapshot`` the runtime serves the MUSHclient introspection
/// world-API from (`GetTriggerInfo`/`GetPluginTriggerList`/…). Rebuilt and
/// pushed lazily — only when the automation set changed since the last push —
/// right before a script could read it.
extension ScriptEngine {
    /// Re-project and push the introspection mirror to the runtime when it's
    /// gone stale. Called at the seams where control is about to enter plugin
    /// Lua (which may call `GetTriggerInfo`/…); a cheap no-op when nothing
    /// changed. Mutations during the upcoming script are deferred effects, so
    /// they're reflected on the *next* sync — matching the rest of the
    /// effect-applied automation model.
    func syncAutomationSnapshot() async {
        guard automationDirty else { return }
        automationDirty = false
        await runtime.setAutomationSnapshot(buildAutomationSnapshot())
    }

    /// Build the snapshot from the current engines + owner map. Cheap: a map
    /// over the (typically small) automation set.
    private func buildAutomationSnapshot() -> AutomationSnapshot {
        var snapshot = AutomationSnapshot()
        snapshot.triggers = triggers.allTriggers.map { trigger in
            TriggerRecord(
                name: trigger.name,
                owner: automationOwners[trigger.id],
                match: trigger.pattern.matchText,
                isRegex: trigger.pattern.isRegex,
                enabled: trigger.enabled,
                gag: trigger.gag,
                keepEvaluating: trigger.continueEvaluation,
                caseSensitive: trigger.caseSensitive,
                sequence: trigger.sequence,
                oneShot: trigger.oneShot,
                group: trigger.group ?? "",
                script: trigger.script ?? "",
                sendText: trigger.sendText ?? "",
                sendTo: Self.sendToCode(trigger.sendTo)
            )
        }
        snapshot.aliases = aliases.allAliases.map { alias in
            AliasRecord(
                name: alias.name,
                owner: automationOwners[alias.id],
                match: alias.pattern.matchText,
                isRegex: alias.pattern.isRegex,
                enabled: alias.enabled,
                keepEvaluating: alias.keepEvaluating,
                caseSensitive: alias.caseSensitive,
                sequence: alias.sequence,
                group: alias.group ?? "",
                sendText: alias.sendText ?? "",
                sendTo: Self.sendToCode(alias.sendTo)
            )
        }
        snapshot.timers = timers.allTimers.map { timer in
            TimerRecord(
                name: timer.label,
                owner: automationOwners[timer.id],
                schedule: timer.schedule,
                enabled: timer.enabled,
                temporary: timer.temporary,
                group: timer.group ?? "",
                sendText: timer.action.sendText ?? "",
                script: timer.action.scriptText ?? "",
                sendTo: timer.action.scriptText == nil ? MUSHSendTo.world : MUSHSendTo.script,
                fireAt: timers.fireDate(for: timer.id)
            )
        }
        return snapshot
    }

    private static func sendToCode(_ target: TriggerTarget) -> Int {
        switch target {
        case .world: MUSHSendTo.world
        case .execute: MUSHSendTo.execute
        case .output: MUSHSendTo.output
        }
    }

    private static func sendToCode(_ target: AliasTarget) -> Int {
        switch target {
        case .world: MUSHSendTo.world
        case .execute: MUSHSendTo.execute
        case .script: MUSHSendTo.script
        case .output: MUSHSendTo.output
        }
    }
}

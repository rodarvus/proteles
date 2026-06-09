import Foundation

/// Maps world-level MUSHclient `<alias>`/`<trigger>` rules to Proteles
/// ``Alias``/``Trigger``. Pure.
///
/// Pattern: MUSHclient wildcard (`*` = capture) maps to ``TriggerPattern/wildcard``
/// (same semantics); `regexp="y"` → ``TriggerPattern/regex``. `send_to` follows
/// the MUSHclient `eSendTo` enum (verified against the reference): 0 world,
/// 2 output, 10 execute (re-parse), 12 script. `ignore_case` → case sensitivity.
public enum MUSHclientScriptMapping {
    private static func pattern(_ rule: MUSHclientWorldFile.ScriptRule) -> TriggerPattern {
        rule.regexp ? .regex(rule.match) : .wildcard(rule.match)
    }

    private static func target(_ sendTo: Int) -> AliasTarget {
        switch sendTo {
        case 2: .output
        case 10: .execute
        case 12: .script
        default: .world
        }
    }

    public static func aliases(from rules: [MUSHclientWorldFile.ScriptRule]) -> [Alias] {
        rules.compactMap { rule in
            guard !rule.match.isEmpty else { return nil }
            let send = rule.send.trimmingCharacters(in: .whitespacesAndNewlines)
            return Alias(
                name: rule.name,
                pattern: pattern(rule),
                caseSensitive: !rule.ignoreCase,
                enabled: rule.enabled,
                sequence: rule.sequence,
                group: rule.group,
                keepEvaluating: rule.keepEvaluating,
                sendText: send.isEmpty ? nil : send,
                sendTo: target(rule.sendTo)
            )
        }
    }

    /// Map world-level `<timer>` rules to Proteles ``MudTimer``s. Interval timers
    /// (`hour`/`minute`/`second`) → `.every(interval, offset:)` (or `.after` when
    /// one-shot); at-time timers → `.atTimeOfDay`. `send_to=12` → `.script`, else
    /// `.send`. Drops timers with an empty body or a zero interval.
    public static func timers(from rules: [MUSHclientWorldFile.Timer]) -> [MudTimer] {
        rules.compactMap { rule in
            let body = rule.send.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let action: TimerAction = rule.sendTo == 12 ? .script(body) : .send(body)

            let schedule: TimerSchedule
            if rule.atTime {
                schedule = .atTimeOfDay(hour: rule.hour, minute: rule.minute, second: rule.second)
            } else {
                let interval = Double(rule.hour * 3600 + rule.minute * 60) + rule.second
                guard interval > 0 else { return nil }
                if rule.oneShot {
                    schedule = .after(interval)
                } else {
                    let offset = Double(rule.offsetHour * 3600 + rule.offsetMinute * 60) + rule.offsetSecond
                    schedule = .every(interval, offset: offset)
                }
            }
            return MudTimer(
                label: rule.name,
                group: rule.group,
                schedule: schedule,
                action: action,
                enabled: rule.enabled,
                temporary: rule.oneShot
            )
        }
    }

    public static func triggers(from rules: [MUSHclientWorldFile.ScriptRule]) -> [Trigger] {
        rules.compactMap { rule in
            guard !rule.match.isEmpty else { return nil }
            let send = rule.send.trimmingCharacters(in: .whitespacesAndNewlines)
            let isScript = rule.sendTo == 12
            return Trigger(
                name: rule.name,
                pattern: pattern(rule),
                caseSensitive: !rule.ignoreCase,
                enabled: rule.enabled,
                sequence: rule.sequence,
                group: rule.group,
                continueEvaluation: rule.keepEvaluating,
                sendText: isScript || send.isEmpty ? nil : send,
                script: isScript && !send.isEmpty ? send : nil
            )
        }
    }
}

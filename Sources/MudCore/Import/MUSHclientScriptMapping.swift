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

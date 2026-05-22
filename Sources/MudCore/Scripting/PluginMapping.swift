import Foundation

/// Maps MUSHclient `<trigger>`/`<alias>`/`<timer>` attribute dictionaries to
/// Proteles' value types, applying MUSHclient's defaults (PLAN.md §7.4).
enum PluginMapping {
    /// MUSHclient `send_to` values seen in the Aardwolf corpus: `12` = send
    /// to script, `14` = script + omit from command history.
    private static let scriptSendTo: Set<String> = ["12", "14"]

    static func trigger(_ attributes: [String: String], send: String) -> Trigger {
        let name = nonEmpty(attributes["name"])
        let (sendText, script) = dispatch(attributes, send: send, name: name)
        return Trigger(
            name: name,
            pattern: pattern(attributes),
            // MUSHclient default ignore_case is "n" → case-sensitive.
            caseSensitive: attributes["ignore_case"] != "y",
            enabled: attributes["enabled"] != "n",
            sequence: Int(attributes["sequence"] ?? "") ?? 100,
            group: nonEmpty(attributes["group"]),
            // MUSHclient default keep_evaluating is "n" → stop after match.
            continueEvaluation: attributes["keep_evaluating"] == "y",
            gag: attributes["omit_from_output"] == "y",
            sendText: sendText,
            script: script
        )
    }

    static func alias(_ attributes: [String: String], send: String) -> Alias {
        let name = nonEmpty(attributes["name"])
        let body = trimmedSend(send)
        let target = aliasTarget(attributes["send_to"])
        let scriptAttr = nonEmpty(attributes["script"])
        // A `script` function attribute takes precedence (call it); else the
        // body is the expansion, routed per send_to.
        let sendText = scriptAttr.map { "\($0)(\(luaString(name ?? "")), matches[0], matches)" }
            ?? body
        return Alias(
            name: name,
            pattern: pattern(attributes),
            caseSensitive: attributes["ignore_case"] != "y",
            enabled: attributes["enabled"] != "n",
            sequence: Int(attributes["sequence"] ?? "") ?? 100,
            group: nonEmpty(attributes["group"]),
            keepEvaluating: attributes["keep_evaluating"] == "y",
            sendText: sendText,
            sendTo: scriptAttr != nil ? .script : target
        )
    }

    static func timer(_ attributes: [String: String], send: String) -> MudTimer? {
        let hours = Double(attributes["hour"] ?? "") ?? 0
        let minutes = Double(attributes["minute"] ?? "") ?? 0
        let secs = Double(attributes["second"] ?? "") ?? 0
        let seconds = hours * 3600 + minutes * 60 + secs
        guard seconds > 0 else { return nil }
        let body = trimmedSend(send)
        let isScript = scriptSendTo.contains(attributes["send_to"] ?? "")
        return MudTimer(
            label: nonEmpty(attributes["name"]),
            group: nonEmpty(attributes["group"]),
            schedule: .every(seconds),
            action: isScript ? .script(body) : .send(body),
            enabled: attributes["enabled"] != "n"
        )
    }

    // MARK: - Private

    private static func pattern(_ attributes: [String: String]) -> TriggerPattern {
        let match = attributes["match"] ?? ""
        // MUSHclient non-regexp matches are whole-line wildcard patterns.
        return attributes["regexp"] == "y" ? .regex(match) : .wildcard(match)
    }

    /// Resolve a trigger's `<send>`/`script` into our (sendText, script) pair.
    private static func dispatch(
        _ attributes: [String: String],
        send: String,
        name: String?
    ) -> (sendText: String?, script: String?) {
        if let function = nonEmpty(attributes["script"]) {
            // MUSHclient calls script(name, line, wildcards); matches[0] is
            // the whole match and `matches` is the wildcard table.
            return (nil, "\(function)(\(luaString(name ?? "")), matches[0], matches)")
        }
        let body = trimmedSend(send)
        guard !body.isEmpty else { return (nil, nil) }
        if scriptSendTo.contains(attributes["send_to"] ?? "") {
            return (nil, body) // run the body as Lua
        }
        return (body, nil) // send to world (with %-substitution)
    }

    private static func aliasTarget(_ sendTo: String?) -> AliasTarget {
        switch sendTo {
        case "12", "14": .script
        case "10": .execute
        case "2": .output
        default: .world
        }
    }

    private static func trimmedSend(_ send: String) -> String {
        send.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// A Lua string literal for `value` (used to embed a trigger name in a
    /// generated function call).
    private static func luaString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

import Foundation

extension SearchAndDestroyHost {
    /// Seed the Lua-side `GetTriggerList`/`GetTriggerInfo` mirror from S&D's
    /// parsed XML triggers. Runtime `AddTriggerEx`/`SetTriggerOption` calls keep
    /// the mirror current after load.
    func seedTriggerMetadata() async throws {
        let entries = automations?.triggers.compactMap { trigger -> String? in
            guard let name = trigger.name else { return nil }
            return [
                "name=\(Self.luaLiteral(name))",
                "group=\(Self.luaLiteral(trigger.group ?? ""))"
            ].joined(separator: ",")
        } ?? []
        guard !entries.isEmpty else { return }
        let table = entries.map { "{\($0)}" }.joined(separator: ",")
        _ = try await runtime.run("__snd_seed_trigger_meta({\(table)})")
    }

    /// Apply the subset of `SetTriggerOption` S&D uses to the host-owned
    /// trigger engine. The generic shim has the same behavior for imported
    /// plugins; S&D runs on its own runtime/engine, so it needs the mirror here.
    func setTriggerOptionByName(name: String, option: String, value: String) {
        guard let id = triggerIDsByName[name],
              var trigger = triggers.allTriggers.first(where: { $0.id == id })
        else { return }
        switch option {
        case "omit_from_output": trigger.gag = Self.mushTruthy(value)
        case "keep_evaluating": trigger.continueEvaluation = Self.mushTruthy(value)
        case "ignore_case": trigger.caseSensitive = !Self.mushTruthy(value)
        case "enabled": trigger.enabled = Self.mushTruthy(value)
        case "sequence":
            guard let sequence = Int(value) else { return }
            trigger.sequence = sequence
        case "match": trigger.pattern = Self.repattern(trigger.pattern, value)
        default: return
        }
        triggers.remove(id: id)
        if (try? triggers.add(trigger)) != nil { triggerIDsByName[name] = trigger.id }
    }

    /// MUSHclient option booleans: truthy unless empty / 0 / n[o] / false / off.
    private static func mushTruthy(_ value: String) -> Bool {
        let normalised = value.trimmingCharacters(in: .whitespaces).lowercased()
        return !(["", "0", "n", "no", "false", "off"].contains(normalised))
    }

    /// Rebuild a trigger pattern with new text, preserving its match kind.
    private static func repattern(_ current: TriggerPattern, _ text: String) -> TriggerPattern {
        switch current {
        case .substring: .substring(text)
        case .beginsWith: .beginsWith(text)
        case .exact: .exact(text)
        case .wildcard: .wildcard(text)
        case .regex: .regex(text)
        }
    }

    private static func luaLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            + "\""
    }
}

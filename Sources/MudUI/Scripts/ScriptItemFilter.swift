import Foundation
import MudCore

/// Case-insensitive substring filtering for the Scripts window's lists
/// (#35 — the imported sets run to hundreds of items; scanning by eye
/// doesn't scale). A query matches an item if any of its user-meaningful
/// text fields contains it: the pattern/key, what it sends or runs, and
/// its name/label/group. An empty (or all-whitespace) query matches
/// everything, so the unfiltered list is the resting state.
enum ScriptItemFilter {
    static func matches(_ trigger: Trigger, query: String) -> Bool {
        matches(query, anyOf: [
            trigger.pattern.text, trigger.sendText, trigger.script,
            trigger.name, trigger.group
        ])
    }

    static func matches(_ alias: Alias, query: String) -> Bool {
        matches(query, anyOf: [
            alias.pattern.text, alias.sendText, alias.name, alias.group
        ])
    }

    static func matches(_ timer: MudTimer, query: String) -> Bool {
        let actionText: String = switch timer.action {
        case .send(let text), .script(let text): text
        }
        return matches(query, anyOf: [timer.label, timer.group, actionText])
    }

    static func matches(_ macro: Macro, query: String) -> Bool {
        let actionText: String = switch macro.action {
        case .command(let text), .script(let text), .replaceInput(let text): text
        }
        return matches(query, anyOf: [
            macro.name, macro.label, actionText,
            KeyChordFormatter.describe(macro.chord)
        ])
    }

    private static func matches(_ query: String, anyOf fields: [String?]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(trimmed) == true }
    }
}

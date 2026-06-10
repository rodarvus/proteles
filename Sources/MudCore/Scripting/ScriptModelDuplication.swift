import Foundation

// Copies of the persisted automation types with a fresh `id`, backing the
// Scripts editor's "Duplicate" action. `id` is a `let`, so a copy can't just
// reassign it — these rebuild through the public init (which defaults a new
// UUID) while carrying every other field over.

public extension Trigger {
    func duplicated() -> Trigger {
        Trigger(
            name: name,
            pattern: pattern,
            caseSensitive: caseSensitive,
            enabled: enabled,
            sequence: sequence,
            group: group,
            continueEvaluation: continueEvaluation,
            oneShot: oneShot,
            gag: gag,
            sendText: sendText,
            sendTo: sendTo,
            script: script,
            highlight: highlight
        )
    }
}

public extension CommandButton {
    func duplicated() -> CommandButton {
        CommandButton(
            label: label,
            action: action,
            kind: kind,
            tint: tint,
            icon: icon,
            hotkeyEcho: hotkeyEcho
        )
    }
}

public extension Alias {
    func duplicated() -> Alias {
        Alias(
            name: name,
            pattern: pattern,
            caseSensitive: caseSensitive,
            enabled: enabled,
            sequence: sequence,
            group: group,
            keepEvaluating: keepEvaluating,
            oneShot: oneShot,
            sendText: sendText,
            sendTo: sendTo
        )
    }
}

public extension MudTimer {
    func duplicated() -> MudTimer {
        MudTimer(
            label: label,
            group: group,
            schedule: schedule,
            action: action,
            enabled: enabled,
            temporary: temporary
        )
    }
}

public extension Macro {
    func duplicated() -> Macro {
        Macro(name: name, chord: chord, action: action, enabled: enabled, label: label)
    }
}

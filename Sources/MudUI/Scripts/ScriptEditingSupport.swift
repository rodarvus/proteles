import MudCore
import SwiftUI

/// The selectable kinds of ``TriggerPattern`` (shared by the trigger and
/// alias editors, which both match on a ``TriggerPattern``).
enum PatternKind: String, CaseIterable, Identifiable {
    case substring, beginsWith, exact, wildcard, regex

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .substring: "Contains"
        case .beginsWith: "Begins with"
        case .exact: "Exact line"
        case .wildcard: "Wildcard (* ?)"
        case .regex: "Regex"
        }
    }
}

extension TriggerPattern {
    /// Which ``PatternKind`` this pattern is.
    var kind: PatternKind {
        switch self {
        case .substring: .substring
        case .beginsWith: .beginsWith
        case .exact: .exact
        case .wildcard: .wildcard
        case .regex: .regex
        }
    }

    /// The pattern's literal/source text (the associated value).
    var text: String {
        switch self {
        case .substring(let value), .beginsWith(let value), .exact(let value),
             .wildcard(let value), .regex(let value):
            value
        }
    }

    /// Rebuild a pattern from a kind and text — used by the editors' two
    /// independent controls (a kind picker and a text field).
    static func make(kind: PatternKind, text: String) -> TriggerPattern {
        switch kind {
        case .substring: .substring(text)
        case .beginsWith: .beginsWith(text)
        case .exact: .exact(text)
        case .wildcard: .wildcard(text)
        case .regex: .regex(text)
        }
    }
}

extension AliasTarget {
    var label: String {
        switch self {
        case .world: "Send to MUD"
        case .execute: "Re-process as input"
        case .script: "Run as Lua script"
        case .output: "Echo locally"
        }
    }
}

extension TriggerTarget {
    var label: String {
        switch self {
        case .world: "Send to MUD"
        case .execute: "Re-process as input"
        case .output: "Echo locally"
        }
    }

    /// The send field's placeholder, matched to where the text will go.
    var fieldLabel: String {
        switch self {
        case .world: "Send to MUD"
        case .execute: "Command (runs through aliases)"
        case .output: "Text to echo"
        }
    }
}

extension Binding where Value == String? {
    /// Bridge an optional-string model field to a `TextField`: an empty
    /// field reads/writes as `nil`.
    func orEmpty() -> Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? "" },
            set: { wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

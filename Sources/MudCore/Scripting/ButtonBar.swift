import Foundation

/// A script/plugin-issued change to the button bar (the v3 scripting API, #15).
/// Mudlet can only toggle pre-made buttons; Proteles lets a plugin/trigger
/// create + update + toggle them. Buttons are addressed by **label** (the
/// script-facing handle). The session forwards these to the app, which applies
/// them to the live ``ButtonBar`` + persists.
public enum ButtonCommand: Sendable, Equatable, Codable {
    /// Add (or replace, by label) a momentary button in `group` (created if new).
    case add(group: String, label: String, command: String)
    /// Add (or replace) a toggle button with on/off commands.
    case toggle(group: String, label: String, on: String, off: String)
    /// Set a toggle button's on/off state by label.
    case setState(label: String, on: Bool)
    /// Remove a button by label.
    case remove(label: String)
}

/// A configurable command-button bar (GH #15) — groups of clickable buttons that
/// fire a command (through the normal pipeline, so aliases/mapper/S&D intercept)
/// or run a script. A dedicated model rather than reusing ``Macro`` (buttons
/// need groups, ordering, toggle state, colour/icon), but it reuses
/// ``MacroAction`` for the action and ``session.fire`` for execution. Persisted
/// per-world inside ``ScriptDocument`` like triggers/aliases/timers/macros.
public struct ButtonBar: Codable, Sendable, Equatable {
    public var groups: [ButtonGroup]

    public init(groups: [ButtonGroup] = []) {
        self.groups = groups
    }

    /// Whether there's anything to show (no groups, or only empty groups).
    public var isEmpty: Bool {
        groups.allSatisfy(\.buttons.isEmpty)
    }

    /// Find a button by id across all groups (with its group), for the scripting
    /// API + toggle-state lookups.
    public func find(_ id: CommandButton.ID) -> (group: ButtonGroup.ID, button: CommandButton)? {
        for group in groups {
            if let button = group.buttons.first(where: { $0.id == id }) {
                return (group.id, button)
            }
        }
        return nil
    }

    /// The first button with `label` (the script-facing handle), or `nil`.
    public func button(label: String) -> CommandButton? {
        groups.lazy.flatMap(\.buttons).first { $0.label == label }
    }

    /// The first button bound to `chord` via its ``CommandButton/hotkeyEcho``,
    /// across all groups (#40). Pure lookup — the caller applies the macro tier
    /// gate (``MacroEngine/chordMayFire(_:context:)``) before firing.
    public func button(forHotkey chord: KeyChord) -> CommandButton? {
        groups.lazy.flatMap(\.buttons).first { $0.hotkeyEcho == chord }
    }

    /// Apply a script-issued `add`/`toggle`/`remove` to the bar (mutating).
    /// `setState` changes only transient toggle state, so it's a no-op here —
    /// the caller applies it via ``button(label:)``.
    public mutating func apply(_ command: ButtonCommand) {
        switch command {
        case .add(let group, let label, let command):
            upsert(group: group, label: label) {
                $0.action = .command(command)
                $0.kind = .momentary
            }
        case .toggle(let group, let label, let on, let off):
            upsert(group: group, label: label) {
                $0.action = .command(on)
                $0.kind = .toggle(off: .command(off))
            }
        case .remove(let label):
            for index in groups.indices {
                groups[index].buttons.removeAll { $0.label == label }
            }
        case .setState:
            break
        }
    }

    /// Update the existing button with `label` (anywhere), else append a new one
    /// to `group` (creating the group if needed).
    private mutating func upsert(group: String, label: String, _ configure: (inout CommandButton) -> Void) {
        for groupIndex in groups.indices {
            if let buttonIndex = groups[groupIndex].buttons.firstIndex(where: { $0.label == label }) {
                configure(&groups[groupIndex].buttons[buttonIndex])
                return
            }
        }
        if !groups.contains(where: { $0.name == group }) {
            groups.append(ButtonGroup(name: group))
        }
        let groupIndex = groups.firstIndex { $0.name == group }!
        var button = CommandButton(label: label, action: .command(""))
        configure(&button)
        groups[groupIndex].buttons.append(button)
    }
}

/// A named page of buttons (the native equivalent of Mudlet's button-bar
/// folders). Shown as a tab/segment in the panel.
public struct ButtonGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var buttons: [CommandButton]

    public init(id: UUID = UUID(), name: String, buttons: [CommandButton] = []) {
        self.id = id
        self.name = name
        self.buttons = buttons
    }
}

/// One button: a label + an action, optionally a two-state toggle, with native
/// styling (tint/icon) and an optional displayed hotkey badge.
public struct CommandButton: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var label: String
    /// Momentary: the action on click. Toggle: the action when switching *on*.
    public var action: MacroAction
    public var kind: Kind
    /// `#RRGGBB` accent tint, or `nil` for the default button colour.
    public var tint: String?
    /// SF Symbol name shown before the label, or `nil`.
    public var icon: String?
    /// A key chord shown as a badge (display only — it doesn't bind the key; the
    /// real binding is a ``Macro``). Lets a button advertise its hotkey.
    public var hotkeyEcho: KeyChord?

    public enum Kind: Sendable, Equatable, Codable {
        /// Fires `action` on each click.
        case momentary
        /// Two-state: `action` switches on, `off` switches off; the panel tracks
        /// the (transient) on/off state and shows it.
        case toggle(off: MacroAction)
    }

    public init(
        id: UUID = UUID(),
        label: String,
        action: MacroAction,
        kind: Kind = .momentary,
        tint: String? = nil,
        icon: String? = nil,
        hotkeyEcho: KeyChord? = nil
    ) {
        self.id = id
        self.label = label
        self.action = action
        self.kind = kind
        self.tint = tint
        self.icon = icon
        self.hotkeyEcho = hotkeyEcho
    }

    public var isToggle: Bool {
        if case .toggle = kind { return true }
        return false
    }

    /// The action to fire given the current toggle state: momentary always fires
    /// `action`; a toggle fires `off` when currently on (about to switch off),
    /// else `action` (switching on).
    public func action(currentlyOn: Bool) -> MacroAction {
        guard case .toggle(let off) = kind else { return action }
        return currentlyOn ? off : action
    }
}

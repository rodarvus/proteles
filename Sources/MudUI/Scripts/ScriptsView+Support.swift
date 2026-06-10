import MudCore
import SwiftUI

/// One row in a scripts list: an enable checkbox, a title, a dimmed
/// subtitle, and (when the item is grouped) a trailing group capsule so
/// related items can be spotted while scrolling. The row dims when disabled.
struct ScriptRow: View {
    let title: String
    let subtitle: String
    var badge: String?
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            enableToggle
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1 : 0.6)
    }

    private var enableToggle: some View {
        Toggle("Enabled", isOn: $isEnabled)
            .labelsHidden()
            .help("Enable or disable this item")
        #if os(macOS)
            .toggleStyle(.checkbox)
        #endif
    }
}

/// A pending destructive action in the Scripts window, held until the user
/// confirms it (DESIGN.md §3.7 — destructive actions confirm or undo; these
/// deletes have no undo, so they confirm).
struct ScriptsDeleteRequest {
    enum Action {
        case deleteTrigger(UUID)
        case deleteAlias(UUID)
        case deleteTimer(UUID)
        case deleteMacro(UUID)
        case deleteButton(UUID)
        case deleteButtonGroup(UUID)
        case restoreDefaultKeypad
    }

    let action: Action
    /// The dialog title, naming the item ("Delete the trigger “foo”?").
    let title: String
    /// The destructive button's label ("Delete Trigger").
    let confirmLabel: String
    let message: String

    private static let noUndo = "You can’t undo this."

    static func trigger(_ trigger: Trigger) -> Self {
        named(
            trigger.pattern.text,
            kind: "trigger",
            noun: "Trigger",
            action: .deleteTrigger(trigger.id)
        )
    }

    static func alias(_ alias: Alias) -> Self {
        named(
            alias.pattern.text,
            kind: "alias",
            noun: "Alias",
            action: .deleteAlias(alias.id)
        )
    }

    static func timer(_ timer: MudTimer) -> Self {
        named(
            timer.label ?? "",
            kind: "timer",
            noun: "Timer",
            action: .deleteTimer(timer.id)
        )
    }

    static func macro(_ macro: Macro) -> Self {
        let name = macro.name?.isEmpty == false
            ? macro.name! : KeyChordFormatter.describe(macro.chord)
        return named(
            name,
            kind: "macro",
            noun: "Macro",
            action: .deleteMacro(macro.id)
        )
    }

    static func button(_ button: CommandButton) -> Self {
        named(
            button.label,
            kind: "button",
            noun: "Button",
            action: .deleteButton(button.id)
        )
    }

    static func buttonGroup(_ group: ButtonGroup) -> Self {
        Self(
            action: .deleteButtonGroup(group.id),
            title: group.name.isEmpty
                ? "Delete this button group?"
                : "Delete the button group “\(group.name)”?",
            confirmLabel: "Delete Group",
            message: "This deletes the group and all \(group.buttons.count) "
                + "button(s) in it. \(noUndo)"
        )
    }

    static let restoreDefaultKeypad = Self(
        action: .restoreDefaultKeypad,
        title: "Restore the default keypad layout?",
        confirmLabel: "Restore Defaults",
        message: "This replaces all keypad commands with the built-in "
            + "navigation set. \(noUndo)"
    )

    private static func named(
        _ name: String,
        kind: String,
        noun: String,
        action: Action
    ) -> Self {
        Self(
            action: action,
            title: name.isEmpty
                ? "Delete this \(kind)?" : "Delete the \(kind) “\(name)”?",
            confirmLabel: "Delete \(noun)",
            message: "This removes it from this world and the running session. "
                + noUndo
        )
    }
}

private struct ScriptsFilterActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

public extension FocusedValues {
    /// "Focus the frontmost Scripts tab's filter field" — published by the
    /// key Scripts window via `focusedSceneValue`, consumed by the app's
    /// **Edit ▸ Filter Scripts** (⌥⌘F — ⌘F proper is Find-in-scrollback,
    /// D-104) menu command, which is disabled (nil) in every other window.
    /// The menu route keeps the shortcut discoverable (DESIGN.md §3.2) — an
    /// invisible in-window button does not reliably register its chord.
    var scriptsFilterAction: (() -> Void)? {
        get { self[ScriptsFilterActionKey.self] }
        set { self[ScriptsFilterActionKey.self] = newValue }
    }
}

extension View {
    /// `onDeleteCommand` is macOS-only; MudUI also builds for iOS, where the
    /// Scripts lists simply don't take the Delete key (touch UIs delete by
    /// swipe/context menu instead).
    @ViewBuilder
    func onDeleteCommandCompat(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
            onDeleteCommand(perform: action)
        #else
            self
        #endif
    }
}

extension ScriptsView {
    static func title(_ text: String, fallback: String) -> String {
        text.isEmpty ? fallback : text
    }

    static func macroTitle(_ macro: Macro) -> String {
        if let name = macro.name, !name.isEmpty { return name }
        return KeyChordFormatter.describe(macro.chord)
    }

    static func timerSummary(_ timer: MudTimer) -> String {
        switch timer.schedule {
        case .after(let delay): "once after \(seconds(delay))"
        case .every(let interval, _): "every \(seconds(interval))"
        case .atTimeOfDay(let hour, let minute, _):
            String(format: "daily at %02d:%02d", hour, minute)
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value))s" : "\(value)s"
    }

    /// The detail column's placeholder when nothing is selected.
    func unavailable(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text("Select an item from the list, or add a new one.")
        )
    }

    /// The list column's placeholder when a kind has no items at all —
    /// says what the thing *is* and offers the first step (DESIGN.md §3.5,
    /// discoverable power; §3.7, no dead surfaces).
    func emptyList(
        _ title: String,
        systemImage: String,
        blurb: String,
        addLabel: String,
        add: @escaping () async -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(blurb)
        } actions: {
            Button(addLabel) { Task { await add() } }
        }
    }
}

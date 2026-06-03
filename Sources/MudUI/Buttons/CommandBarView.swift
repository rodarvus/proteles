import MudCore
import SwiftUI

/// The command-button bar panel (#15): group tabs + an **adaptive** button grid
/// that flows to fill the docked/floating area — a horizontal strip when the
/// panel is wide and short, a column/grid when tall and narrow (orientation
/// follows placement, no manual columns). Buttons fire through the session;
/// toggle buttons show their on/off state. Authoring is in Scripts ▸ Buttons.
public struct CommandBarView: View {
    private let scripts: ScriptsModel
    @State private var selectedGroup: UUID?

    public init(scripts: ScriptsModel) {
        self.scripts = scripts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if scripts.buttonBar.isEmpty {
                emptyState
            } else {
                if groups.count > 1 { groupTabs }
                grid
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var groups: [ButtonGroup] {
        scripts.buttonBar.groups
    }

    private var currentGroup: ButtonGroup? {
        groups.first { $0.id == selectedGroup } ?? groups.first
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No command buttons yet.").font(.callout).foregroundStyle(.secondary)
            Text("Add buttons in Scripts ▸ Buttons.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var groupTabs: some View {
        Picker("Group", selection: Binding(
            get: { currentGroup?.id ?? groups.first?.id },
            set: { selectedGroup = $0 }
        )) {
            ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(currentGroup?.buttons ?? []) { button in
                    CommandButtonCell(
                        button: button,
                        isOn: scripts.buttonToggleStates[button.id] ?? false
                    ) {
                        Task { await scripts.fireButton(button.id) }
                    }
                }
            }
        }
    }
}

/// One button tile: icon + label (+ a hotkey-echo badge), tinted; a toggle fills
/// solid when on.
private struct CommandButtonCell: View {
    let button: CommandButton
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = button.icon, !icon.isEmpty {
                    Image(systemName: icon)
                }
                Text(button.label).lineLimit(1).truncationMode(.tail)
                if let chord = button.hotkeyEcho {
                    Text(KeyChordFormatter.describe(chord))
                        .font(.caption2)
                        .foregroundStyle(filled ? .white.opacity(0.8) : .secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                filled ? tint.opacity(0.9) : tint.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(filled ? .white : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.4), lineWidth: filled ? 0 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(button.isToggle ? "\(button.label) (toggle)" : button.label)
    }

    /// A toggle that's on draws solid; momentary + toggle-off draw tinted-light.
    private var filled: Bool {
        button.isToggle && isOn
    }

    private var tint: Color {
        button.tint.map { Color(hex: $0) } ?? .accentColor
    }
}

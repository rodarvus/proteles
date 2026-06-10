import MudCore
import SwiftUI

/// The command-button bar panel (#15): group tabs + an **adaptive** button grid
/// that flows to fill the docked/floating area — a horizontal strip when the
/// panel is wide and short, a column/grid when tall and narrow (orientation
/// follows placement, no manual columns). Buttons fire through the session;
/// toggle buttons show their on/off state. Authoring is in Scripts ▸ Buttons.
public struct CommandBarView: View {
    private let scripts: ScriptsModel
    /// Opens the Scripts window on the Buttons tab (wired by the app); when
    /// absent the empty state is text-only. Keeps the panel's empty state
    /// actionable instead of a dead end (DESIGN.md §3.7, D-106).
    private let onOpenEditor: (() -> Void)?
    @State private var selectedGroup: UUID?

    public init(scripts: ScriptsModel, onOpenEditor: (() -> Void)? = nil) {
        self.scripts = scripts
        self.onOpenEditor = onOpenEditor
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
            if let onOpenEditor {
                Button("Open Scripts ▸ Buttons") { onOpenEditor() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .font(.caption)
            } else {
                Text("Add buttons in Scripts ▸ Buttons.").font(.caption).foregroundStyle(.tertiary)
            }
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

// CommandButtonCell (the tile view) lives in CommandButtonCell.swift — it's
// shared with the button editor's live preview (D-106).

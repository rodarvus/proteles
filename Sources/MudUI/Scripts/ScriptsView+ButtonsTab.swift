import MudCore
import SwiftUI

/// The Scripts window's Buttons tab (D-106 polish pass): a filterable
/// group-sectioned list with drag-reorder (list order *is* the panel's
/// order), explicit group rename via the context menu (the name is no longer
/// a silently-editable header field), Duplicate on ⌘D like every other tab,
/// and confirm-gated deletes. Split from `ScriptsView+Tabs.swift` for the
/// file budget.
extension ScriptsView {
    private var isFilteringButtons: Bool {
        !buttonQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Groups with their (filtered) buttons. An active filter hides groups
    /// with no matches; an empty filter shows every group, including empty
    /// ones (they need to be visible to rename/fill/delete).
    private var filteredButtonGroups: [(group: ButtonGroup, buttons: [CommandButton])] {
        model.buttonBar.groups.compactMap { group in
            guard isFilteringButtons else { return (group, group.buttons) }
            let hits = group.buttons.filter { ScriptItemFilter.matches($0, query: buttonQuery) }
            return hits.isEmpty ? nil : (group, hits)
        }
    }

    var buttonsTab: some View {
        NavigationSplitView {
            Group {
                if model.buttonBar.groups.isEmpty {
                    emptyList(
                        "No Button Groups",
                        systemImage: "rectangle.grid.2x2",
                        blurb: "Buttons appear in the command-bar panel — group "
                            + "related commands into a named page.",
                        addLabel: "Add Group",
                        add: { await model.addButtonGroup() }
                    )
                } else if filteredButtonGroups.isEmpty {
                    ContentUnavailableView.search(text: buttonQuery)
                } else {
                    buttonsList
                }
            }
            .searchable(text: $buttonQuery, placement: .sidebar, prompt: "Filter")
            .searchFocused($filterFocus, equals: .buttons)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar { buttonsToolbar }
        } detail: {
            if let id = model.selectedButtonID, let binding = model.binding(forButton: id) {
                CommandButtonEditor(button: binding)
            } else {
                unavailable("No Button Selected", systemImage: "rectangle.grid.2x2")
            }
        }
    }

    private var buttonsList: some View {
        List(selection: $model.selectedButtonID) {
            ForEach(filteredButtonGroups, id: \.group.id) { entry in
                Section {
                    ForEach(entry.buttons) { button in
                        buttonRow(button)
                    }
                    // Reorder follows the true list order, so it's off while a
                    // filter is hiding rows (indices wouldn't line up).
                    .onMove(perform: isFilteringButtons ? nil : { offsets, destination in
                        Task {
                            await model.moveButtons(
                                inGroup: entry.group.id, from: offsets, to: destination
                            )
                        }
                    })
                    if !isFilteringButtons {
                        Button {
                            Task { await model.addButton(toGroup: entry.group.id) }
                        } label: {
                            Label("Add Button", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    groupHeader(entry.group)
                }
            }
        }
        .onDeleteCommandCompat {
            guard let button = model.buttonBar.groups
                .flatMap(\.buttons)
                .first(where: { $0.id == model.selectedButtonID })
            else { return }
            deleteRequest = .button(button)
        }
    }

    private func buttonRow(_ button: CommandButton) -> some View {
        HStack(spacing: 6) {
            if let icon = button.icon, !icon.isEmpty {
                ButtonIconView(icon: icon)
                    .foregroundStyle(button.tint.map { Color(hex: $0) } ?? .accentColor)
                    .frame(minWidth: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(button.label.isEmpty ? "—" : button.label)
                Text(button.action.text.isEmpty ? "—" : button.action.text)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .tag(button.id)
        .contextMenu {
            Button("Duplicate") { Task { await model.duplicateButton(button.id) } }
            Button("Delete", role: .destructive) { deleteRequest = .button(button) }
        }
    }

    /// Group header: plain text; renaming is an explicit act (context menu →
    /// a focused field, Return/Esc ends it) instead of a hidden inline field.
    private func groupHeader(_ group: ButtonGroup) -> some View {
        HStack {
            if renamingGroupID == group.id {
                TextField("Group", text: model.bindingForGroupName(group.id))
                    .textFieldStyle(.plain)
                    .focused($groupRenameFocus, equals: group.id)
                    .onSubmit { renamingGroupID = nil }
                    .onExitCommand { renamingGroupID = nil }
            } else {
                Text(group.name.isEmpty ? "Untitled Group" : group.name)
            }
            Spacer()
        }
        .contextMenu {
            Button("Rename Group") { beginRenamingGroup(group.id) }
            Button("Move Group Up") { Task { await moveGroup(group.id, by: -1) } }
                .disabled(groupIndex(group.id) == 0)
            Button("Move Group Down") { Task { await moveGroup(group.id, by: 1) } }
                .disabled(groupIndex(group.id) == model.buttonBar.groups.count - 1)
            Divider()
            Button("Add Button") { Task { await model.addButton(toGroup: group.id) } }
            Button("Delete Group…", role: .destructive) { deleteRequest = .buttonGroup(group) }
        }
    }

    @ToolbarContentBuilder
    private var buttonsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await addInButtonsTab() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a button to the selected group (⌘N)")
            .keyboardShortcut(selectedTab == .buttons
                ? KeyboardShortcut("n", modifiers: .command) : nil)
            Button {
                if let id = model.selectedButtonID {
                    Task { await model.duplicateButton(id) }
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .help("Duplicate (⌘D)")
            .keyboardShortcut(selectedTab == .buttons
                ? KeyboardShortcut("d", modifiers: .command) : nil)
            .disabled(model.selectedButtonID == nil)
            Button(role: .destructive) {
                guard let button = model.buttonBar.groups
                    .flatMap(\.buttons)
                    .first(where: { $0.id == model.selectedButtonID })
                else { return }
                deleteRequest = .button(button)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete (⌫ in the list)")
            .disabled(model.selectedButtonID == nil)
            Button {
                Task { await model.addButtonGroup() }
            } label: {
                Label("Add Group", systemImage: "folder.badge.plus")
            }
            .help("Add a button group/page")
        }
    }

    // MARK: - Helpers

    private func beginRenamingGroup(_ id: UUID) {
        renamingGroupID = id
        groupRenameFocus = id
    }

    private func groupIndex(_ id: UUID) -> Int {
        model.buttonBar.groups.firstIndex { $0.id == id } ?? 0
    }

    /// Move a group one slot up/down (`by` = ±1). `toOffset` is in
    /// post-removal coordinates, hence the +2 when moving down.
    private func moveGroup(_ id: UUID, by delta: Int) async {
        let index = groupIndex(id)
        let destination = delta < 0 ? index - 1 : index + 2
        guard destination >= 0, destination <= model.buttonBar.groups.count else { return }
        await model.moveButtonGroups(from: IndexSet(integer: index), to: destination)
    }

    /// ⌘N on the Buttons tab: add a button to the selected button's group
    /// (else the first group); with no groups yet, start one.
    private func addInButtonsTab() async {
        let groups = model.buttonBar.groups
        guard !groups.isEmpty else {
            await model.addButtonGroup()
            return
        }
        let target = groups.first { group in
            group.buttons.contains { $0.id == model.selectedButtonID }
        } ?? groups[0]
        await model.addButton(toGroup: target.id)
    }
}

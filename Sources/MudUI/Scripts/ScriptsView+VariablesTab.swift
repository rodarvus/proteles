import MudCore
import SwiftUI

/// The Scripts window's Variables tab (#69): the user's own world variables
/// (the `_user` scope — see ``ScriptsModel/refreshVariables()``), shown as a
/// native two-column **Name | Value** table you edit in place — the same shape
/// as MUSHclient's Game ▸ Configure ▸ Variables page. A plain list+detail split
/// wasted the whole right pane on a two-field record; a ``Table`` shows every
/// variable's name and value at once and edits inline. Plugin/S&D variables are
/// deliberately absent (their plugins own them; hand-editing live state corrupts
/// them), so the list is empty until you create a variable.
extension ScriptsView {
    private var filteredVariables: [VariableEntry] {
        guard !variableQuery.isEmpty else { return model.variables }
        return model.variables.filter { entry in
            entry.name.localizedCaseInsensitiveContains(variableQuery)
                || entry.value.localizedCaseInsensitiveContains(variableQuery)
        }
    }

    var variablesTab: some View {
        Group {
            if model.variables.isEmpty {
                ContentUnavailableView {
                    Label("No Variables", systemImage: "curlybraces")
                } description: {
                    Text("A variable stores a named value your scripts and aliases "
                        + "can read and set (MUSHclient Get/SetVariable). Plugins keep "
                        + "their own variables privately.")
                } actions: {
                    Button("Add Variable") { Task { await model.addVariable() } }
                }
            } else if filteredVariables.isEmpty {
                ContentUnavailableView.search(text: variableQuery)
            } else {
                variablesTable
            }
        }
        .searchable(text: $variableQuery, placement: .automatic, prompt: "Filter")
        .searchFocused($filterFocus, equals: .variables)
        .task { await model.refreshVariables() }
        .toolbar { variablesToolbar }
    }

    private var variablesTable: some View {
        Table(filteredVariables, selection: $model.selectedVariableID) {
            TableColumn("Name") { entry in
                VariableNameCell(name: entry.name) { newName in
                    await model.renameVariable(id: entry.id, to: newName)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Value") { entry in
                VariableValueCell(
                    value: model.valueBinding(forVariable: entry.id) ?? .constant(entry.value)
                )
            }
        }
        .onDeleteCommandCompat { confirmDeleteSelectedVariable() }
        .contextMenu(forSelectionType: VariableEntry.ID.self) { ids in
            if let id = ids.first, let entry = model.variableEntry(id) {
                Button("Delete", role: .destructive) { deleteRequest = .variable(entry) }
            }
        }
    }

    @ToolbarContentBuilder
    private var variablesToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { variableQuery = ""; await model.addVariable() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add (⌘N)")
            .keyboardShortcut(
                selectedTab == .variables ? KeyboardShortcut("n", modifiers: .command) : nil
            )
            Button(role: .destructive) { confirmDeleteSelectedVariable() } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete (⌫ in the list)")
            .disabled(model.selectedVariableID == nil)
        }
    }

    private func confirmDeleteSelectedVariable() {
        guard let entry = model.variables.first(where: { $0.id == model.selectedVariableID })
        else { return }
        deleteRequest = .variable(entry)
    }
}

/// The editable Name cell: a local draft that commits on Return (or when the
/// field loses focus), so typing a new name doesn't rename per keystroke —
/// rename is a delete-then-add, which would otherwise leave a trail of partial
/// variables. A fresh row (the id is `scope` + name) re-creates this cell, so
/// the draft tracks the current name.
private struct VariableNameCell: View {
    let name: String
    let rename: (String) async -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(name: String, rename: @escaping (String) async -> Void) {
        self.name = name
        self.rename = rename
        _draft = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $draft)
            .labelsHidden()
            .font(.body.monospaced())
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else {
            draft = name // revert an empty/unchanged edit
            return
        }
        Task { await rename(trimmed) }
    }
}

/// The editable Value cell: binds straight through to the runtime + store
/// (persists as you type, like the trigger/alias editors). Values are plain
/// text, exactly like MUSHclient's Get/SetVariable.
private struct VariableValueCell: View {
    @Binding var value: String

    var body: some View {
        TextField("Value", text: $value)
            .labelsHidden()
            .font(.body.monospaced())
    }
}

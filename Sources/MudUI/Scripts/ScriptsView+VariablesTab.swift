import MudCore
import SwiftUI

/// The Scripts window's Variables tab (#69): the user's own world variables (the
/// `_user` scope — see ``ScriptsModel/refreshVariables()``) in a native two-column
/// **Name | Value** table, the same shape as MUSHclient's Game ▸ Configure ▸
/// Variables page. The table is read-only/selectable; add + edit happen in a
/// small sheet (``VariableEditSheet``) so the keyboard story is the standard one
/// (DESIGN.md §3.2): Add → name field focused → Tab to Value → Return commits,
/// Escape cancels. Inline-editing the table cells fought SwiftUI's focus model
/// (no reliable auto-focus on a new row, Tab created rows) — the sheet is what
/// MUSHclient does and it just works. Plugin/S&D variables never appear here.
extension ScriptsView {
    /// Request to open the add/edit sheet — `original == nil` means Add.
    struct VariableEditorRequest: Identifiable {
        let id = UUID()
        let original: VariableEntry?
    }

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
                    Button("Add Variable") { variableEditor = .init(original: nil) }
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
        .sheet(item: $variableEditor) { request in
            VariableEditSheet(
                original: request.original,
                existingNames: Set(model.variables.map(\.name))
            ) { name, value in
                await model.commitVariable(editing: request.original, name: name, value: value)
            }
        }
    }

    private var variablesTable: some View {
        Table(filteredVariables, selection: $model.selectedVariableID) {
            TableColumn("Name") { entry in
                Text(entry.name).font(.body.monospaced())
            }
            .width(min: 160, ideal: 220)
            TableColumn("Value") { entry in
                Text(entry.value.isEmpty ? "—" : entry.value)
                    .font(.body.monospaced())
                    .foregroundStyle(entry.value.isEmpty ? .secondary : .primary)
            }
        }
        .onDeleteCommandCompat { confirmDeleteSelectedVariable() }
        // Return opens the selected row in the editor (the keyboard edit path).
        .onKeyPress(.return) {
            guard let entry = selectedVariable else { return .ignored }
            variableEditor = .init(original: entry)
            return .handled
        }
        .contextMenu(forSelectionType: VariableEntry.ID.self) { ids in
            if let id = ids.first, let entry = model.variableEntry(id) {
                Button("Edit…") { variableEditor = .init(original: entry) }
                Button("Delete", role: .destructive) { deleteRequest = .variable(entry) }
            }
        }
    }

    @ToolbarContentBuilder
    private var variablesToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { variableEditor = .init(original: nil) } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add (⌘N)")
            .keyboardShortcut(
                selectedTab == .variables ? KeyboardShortcut("n", modifiers: .command) : nil
            )
            Button {
                if let entry = selectedVariable { variableEditor = .init(original: entry) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .help("Edit (↵)")
            .disabled(model.selectedVariableID == nil)
            Button(role: .destructive) { confirmDeleteSelectedVariable() } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete (⌫ in the list)")
            .disabled(model.selectedVariableID == nil)
        }
    }

    private var selectedVariable: VariableEntry? {
        model.variables.first { $0.id == model.selectedVariableID }
    }

    private func confirmDeleteSelectedVariable() {
        guard let entry = selectedVariable else { return }
        deleteRequest = .variable(entry)
    }
}

/// The add/edit sheet: a Name field (auto-focused) and a Value field. Standard
/// keyboard form behaviour — **Tab** moves Name→Value, **Return** commits (the
/// default button), **Escape** cancels — so a variable can be created end to end
/// without the mouse. Mirrors MUSHclient's EditVariable dialog.
private struct VariableEditSheet: View {
    enum Field: Hashable { case name, value }

    let original: VariableEntry?
    let existingNames: Set<String>
    let commit: (_ name: String, _ value: String) async -> Void

    @State private var name: String
    @State private var value: String
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    init(
        original: VariableEntry?,
        existingNames: Set<String>,
        commit: @escaping (_ name: String, _ value: String) async -> Void
    ) {
        self.original = original
        self.existingNames = existingNames
        self.commit = commit
        _name = State(initialValue: original?.name ?? "")
        _value = State(initialValue: original?.value ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adding (or renaming onto) a name another variable already uses.
    private var nameConflict: Bool {
        !trimmedName.isEmpty && trimmedName != original?.name && existingNames.contains(trimmedName)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !nameConflict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $name)
                    .font(.body.monospaced())
                    .focused($focus, equals: .name)
                TextField("Value", text: $value)
                    .font(.body.monospaced())
                    .focused($focus, equals: .value)
                if nameConflict {
                    Label(
                        "A variable named “\(trimmedName)” already exists.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 440)
        .onAppear { focus = .name }
    }

    private func save() {
        guard canSave else { return }
        let committedName = trimmedName
        let committedValue = value
        Task { await commit(committedName, committedValue) }
        dismiss()
    }
}

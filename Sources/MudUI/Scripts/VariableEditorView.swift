import MudCore
import SwiftUI

/// The Variables tab's detail editor (#69): the scope (read-only — variables
/// stay in the scope they were created in), the name (rename on Return), and
/// the value. The value binds live (persists as you type, like the other
/// editors); the name commits on submit so typing a new name doesn't create a
/// trail of partial variables. The parent re-creates this view per selection
/// (`.id(entry.id)`), so the local name draft tracks the selected variable.
struct VariableEditorView: View {
    let entry: VariableEntry
    @Binding var value: String
    let rename: (String) async -> Void
    @State private var nameDraft: String

    init(
        entry: VariableEntry,
        value: Binding<String>,
        rename: @escaping (String) async -> Void
    ) {
        self.entry = entry
        _value = value
        self.rename = rename
        _nameDraft = State(initialValue: entry.name)
    }

    var body: some View {
        Form {
            Section("Variable") {
                LabeledContent("Scope", value: ScriptsView.scopeLabel(entry.scope))
                TextField("Name", text: $nameDraft)
                    .font(.body.monospaced())
                    .onSubmit { commitRename() }
                    .help("The variable's name. Press Return to rename it.")
            }
            Section("Value") {
                TextField("Value", text: $value, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(3...12)
                    .help("Stored as text, exactly like MUSHclient's Get/SetVariable.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entry.name.isEmpty ? "Variable" : entry.name)
    }

    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else {
            nameDraft = entry.name // revert an empty/unchanged edit
            return
        }
        Task { await rename(trimmed) }
    }
}

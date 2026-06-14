import MudCore
import SwiftUI

/// The Scripts window's Variables tab (#69): a filterable list of the world's
/// scoped variables (≈ MUSHclient Game ▸ Configure ▸ Variables) + a name/value
/// editor. Split into its own file like the Buttons tab. Variables aren't in the
/// script document, so this tab talks to the session's variable API directly
/// (``ScriptsModel+Variables``) rather than the per-tab Add/Duplicate/scope
/// toolbar the other tabs share — there's no "shared vs per-character" axis and
/// duplicating a variable makes no sense, so the toolbar is just Add + Delete.
extension ScriptsView {
    private var filteredVariables: [VariableEntry] {
        guard !variableQuery.isEmpty else { return model.variables }
        return model.variables.filter { entry in
            entry.name.localizedCaseInsensitiveContains(variableQuery)
                || entry.value.localizedCaseInsensitiveContains(variableQuery)
                || Self.scopeLabel(entry.scope).localizedCaseInsensitiveContains(variableQuery)
        }
    }

    var variablesTab: some View {
        NavigationSplitView {
            Group {
                if model.variables.isEmpty {
                    emptyList(
                        "No Variables",
                        systemImage: "curlybraces",
                        blurb: "A variable stores a named value your scripts and "
                            + "plugins can read and set (MUSHclient Get/SetVariable).",
                        addLabel: "Add Variable",
                        add: { await model.addVariable() }
                    )
                } else if filteredVariables.isEmpty {
                    ContentUnavailableView.search(text: variableQuery)
                } else {
                    variablesList
                }
            }
            .searchable(text: $variableQuery, placement: .sidebar, prompt: "Filter")
            .searchFocused($filterFocus, equals: .variables)
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            .task { await model.refreshVariables() }
            .toolbar { variablesToolbar }
        } detail: {
            // Single-line `if let` (via this helper) so swiftformat doesn't wrap
            // the opening brace onto its own line, which swiftlint then rejects.
            if let inputs = variableDetailInputs() {
                VariableEditorView(
                    entry: inputs.entry,
                    value: inputs.value,
                    rename: { newName in await model.renameVariable(id: inputs.entry.id, to: newName) }
                )
                .id(inputs.entry.id)
            } else {
                unavailable("No Variable Selected", systemImage: "curlybraces")
            }
        }
    }

    /// The selected variable's entry + a binding to its value, or nil when
    /// nothing (valid) is selected — collapsed into one optional so the detail
    /// view's `if let` stays a single line (see the brace note above).
    private func variableDetailInputs() -> (entry: VariableEntry, value: Binding<String>)? {
        guard let id = model.selectedVariableID,
              let entry = model.variableEntry(id),
              let value = model.valueBinding(forVariable: id)
        else { return nil }
        return (entry, value)
    }

    private var variablesList: some View {
        List(selection: $model.selectedVariableID) {
            ForEach(filteredVariables) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(entry.name)
                            .font(.body.monospaced())
                            .lineLimit(1)
                        Spacer()
                        if !entry.isUserScope {
                            Text(Self.scopeLabel(entry.scope))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .lineLimit(1)
                        }
                    }
                    Text(entry.value.isEmpty ? "—" : entry.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(entry.id)
                .contextMenu {
                    Button("Delete", role: .destructive) { deleteRequest = .variable(entry) }
                }
            }
        }
        .onDeleteCommandCompat { confirmDeleteSelectedVariable() }
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

    /// A human-readable scope label: the user scope reads "World", S&D is named,
    /// other plugin scopes show their (opaque) id — the editor shows it in full.
    static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case VariableEntry.userScope: "World"
        case SearchAndDestroyHost.pluginID: "Search-and-Destroy"
        default: "Plugin"
        }
    }
}

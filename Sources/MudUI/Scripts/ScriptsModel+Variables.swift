import MudCore
import SwiftUI

/// One row in the Variables tab: a scope (`_user` for the user's own scripts,
/// else a plugin id), a name, and a string value — the flattened form of the
/// session's `scope → name → value` map. Identity is `scope` + name, so the
/// list selection survives a value edit but changes on rename (which is a
/// delete-then-add under the hood).
public struct VariableEntry: Identifiable, Hashable, Sendable {
    /// The reserved scope for the user's own (non-plugin) variables.
    public static let userScope = "_user"

    public let scope: String
    public let name: String
    public let value: String

    public var id: String {
        scope + "\u{1f}" + name
    }

    public init(scope: String, name: String, value: String) {
        self.scope = scope
        self.name = name
        self.value = value
    }

    /// Whether this is one of the user's own variables (vs. a plugin's).
    public var isUserScope: Bool {
        scope == Self.userScope
    }
}

/// The Variables tab's CRUD (#69), mirroring the trigger/alias pattern but over
/// the session's variable API rather than a ``ScriptStore`` — variables live in
/// the live runtimes + the per-world ``VariableStore``, not the script document.
@MainActor
public extension ScriptsModel {
    /// Re-read every scope from the session and flatten into sorted rows
    /// (user scope first, then plugin scopes; by name within a scope).
    func refreshVariables() async {
        let scopes = await session.variableScopes()
        var entries: [VariableEntry] = []
        for (scope, vars) in scopes {
            for (name, value) in vars {
                entries.append(VariableEntry(scope: scope, name: name, value: value))
            }
        }
        variables = entries.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                if lhs.isUserScope != rhs.isUserScope { return lhs.isUserScope }
                return lhs.scope < rhs.scope
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The entry for an id, if still present.
    func variableEntry(_ id: VariableEntry.ID) -> VariableEntry? {
        variables.first { $0.id == id }
    }

    /// Add a new, empty variable in the user scope and select it. New variables
    /// always land in `_user` — plugin scopes are owned by their plugins.
    func addVariable() async {
        let name = uniqueUserVariableName()
        await session.setVariable(scope: VariableEntry.userScope, name: name, value: "")
        await refreshVariables()
        selectedVariableID = VariableEntry(scope: VariableEntry.userScope, name: name, value: "").id
    }

    /// Delete the selected variable, then select the next remaining one.
    func deleteSelectedVariable() async {
        guard let id = selectedVariableID, let entry = variableEntry(id) else { return }
        await session.deleteVariable(scope: entry.scope, name: entry.name)
        await refreshVariables()
        selectedVariableID = variables.first?.id
    }

    /// Rename a variable within its scope (carrying its value over) and keep it
    /// selected under its new id. No-op on an empty or unchanged name.
    func renameVariable(id: VariableEntry.ID, to newName: String) async {
        guard let entry = variableEntry(id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        await session.renameVariable(
            scope: entry.scope, from: entry.name, to: trimmed, value: entry.value
        )
        await refreshVariables()
        selectedVariableID = VariableEntry(scope: entry.scope, name: trimmed, value: entry.value).id
    }

    /// A binding to a variable's value: edits write straight through to the
    /// owning runtime + store (like the trigger/alias editors persist on every
    /// keystroke). The id is stable across value edits, so selection holds.
    func valueBinding(forVariable id: VariableEntry.ID) -> Binding<String>? {
        guard let entry = variableEntry(id) else { return nil }
        return Binding(
            get: { [weak self] in self?.variableEntry(id)?.value ?? "" },
            set: { [weak self] newValue in
                guard let self else { return }
                if let index = variables.firstIndex(where: { $0.id == id }) {
                    variables[index] = VariableEntry(
                        scope: entry.scope, name: entry.name, value: newValue
                    )
                }
                Task {
                    await self.session.setVariable(
                        scope: entry.scope, name: entry.name, value: newValue
                    )
                }
            }
        )
    }

    /// A user-scope name not already in use (`variable`, `variable_2`, …).
    private func uniqueUserVariableName() -> String {
        let taken = Set(
            variables.filter(\.isUserScope).map(\.name)
        )
        guard taken.contains("variable") else { return "variable" }
        var index = 2
        while taken.contains("variable_\(index)") {
            index += 1
        }
        return "variable_\(index)"
    }
}

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
    /// Re-read the **user** scope from the session and present it sorted by
    /// name. Only `_user` is shown — the variables you (or your triggers/
    /// aliases/console) create, plus any imported world variables. Plugin and
    /// Search-and-Destroy scopes hold those plugins' private state and are never
    /// shown or editable here, matching MUSHclient's world Variables page (and
    /// so a user who hasn't made a variable sees an empty list).
    func refreshVariables() async {
        let userVars = await session.variableScopes()[VariableEntry.userScope] ?? [:]
        variables = userVars
            .map { VariableEntry(scope: VariableEntry.userScope, name: $0.key, value: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The entry for an id, if still present.
    func variableEntry(_ id: VariableEntry.ID) -> VariableEntry? {
        variables.first { $0.id == id }
    }

    /// Commit the add/edit sheet: create a new user variable, or apply an edit
    /// to `original` (a value change and/or a rename). Adding a name that already
    /// exists overwrites it. The name is trimmed; an empty name is a no-op. The
    /// committed variable ends up selected.
    func commitVariable(editing original: VariableEntry?, name rawName: String, value: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let original, original.name != name {
            // Rename carries the (possibly edited) value over to the new name.
            await session.renameVariable(
                scope: VariableEntry.userScope, from: original.name, to: name, value: value
            )
        } else {
            await session.setVariable(scope: VariableEntry.userScope, name: name, value: value)
        }
        await refreshVariables()
        selectedVariableID = VariableEntry(scope: VariableEntry.userScope, name: name, value: value).id
    }

    /// Delete the selected variable, then select the next remaining one.
    func deleteSelectedVariable() async {
        guard let id = selectedVariableID, let entry = variableEntry(id) else { return }
        await session.deleteVariable(scope: entry.scope, name: entry.name)
        await refreshVariables()
        selectedVariableID = variables.first?.id
    }
}

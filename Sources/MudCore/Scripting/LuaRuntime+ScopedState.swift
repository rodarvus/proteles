import Foundation

/// Host-facing controls for the runtime's scoped, plugin-aware state — the
/// scoped variables (`proteles.getVar`/`setVar`/`deleteVar`) and the ambient
/// `proteles.info`/`pluginID` context. The loader sets the scope + context
/// per plugin; the host hydrates/persists variables around runs.
public extension LuaRuntime {
    /// Set the scope `getVar`/`setVar`/`deleteVar` operate on (a plugin id,
    /// or the default user scope). The loader sets this before running a
    /// plugin's script and its callbacks.
    func setVariableScope(_ scope: String) {
        currentVariableScope = scope
    }

    /// Set the ambient context `proteles.info`/`proteles.pluginID` report.
    func setPluginContext(_ context: PluginContext) {
        pluginContext = context
    }

    /// Replace all in-memory variables (e.g. hydrating from disk on connect).
    /// Clears the dirty set.
    func loadVariables(_ all: [String: [String: String]]) {
        variables = all
        dirtyVariableScopes.removeAll()
    }

    /// A snapshot of every scope's variables (for persistence).
    func variablesSnapshot() -> [String: [String: String]] {
        variables
    }

    /// The variables in one scope.
    func variables(inScope scope: String) -> [String: String] {
        variables[scope] ?? [:]
    }

    /// The scopes mutated since the last call, clearing the set. Lets the
    /// host persist only what changed.
    func takeDirtyVariableScopes() -> Set<String> {
        defer { dirtyVariableScopes.removeAll() }
        return dirtyVariableScopes
    }
}

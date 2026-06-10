import CLua
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

    /// Set the ambient context `proteles.info`/`proteles.pluginID` report, and
    /// remember it by plugin id so callbacks/owned scripts can re-enter it.
    func setPluginContext(_ context: PluginContext) {
        pluginContext = context
        if !context.pluginID.isEmpty { pluginContexts[context.pluginID] = context }
    }

    /// Mirror S&D's shim-readable accessor values into the global
    /// `__snd_state` table, so the compat shim's `CallPlugin(<S&D id>,
    /// "target_as_json")` (and friends) can answer synchronously — the
    /// `proteles.sndCall` effect path is fire-and-forget and can never carry a
    /// return value back to the calling Lua. A nil field means the loaded S&D
    /// doesn't define that accessor; the shim then returns no result (the
    /// callers' documented degrade path). Keys match the accessor names.
    func setSearchAndDestroyShimState(target: String?, targets: String?, gotoCount: String?) {
        lua_createtable(state, 0, 3)
        for (name, value) in [
            ("target_as_json", target),
            ("targets_as_json", targets),
            ("goto_list_count", gotoCount)
        ] {
            guard let value else { continue }
            lua_pushstring(state, value)
            lua_setfield(state, -2, name)
        }
        clua_setglobal(state, "__snd_state")
    }

    /// Mark a natively-bridged MUSHclient plugin id present/absent (the
    /// session calls this as the mapper / S&D host attach or unload).
    func setBridgedPlugin(_ id: String, installed: Bool) {
        if installed {
            bridgedPluginIDs.insert(id)
        } else {
            bridgedPluginIDs.remove(id)
        }
    }

    /// Set the per-character Databases directory surfaced by
    /// `proteles.databaseDir()`. Called by the session once the character is known.
    func setDatabasesDirectory(_ path: String) {
        databasesDirectory = path
    }

    /// Update the live connection state reported by `proteles.isConnected`.
    func setConnected(_ value: Bool) {
        connected = value
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

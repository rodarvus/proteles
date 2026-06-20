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

    /// Update the configured output font name reported by
    /// `GetAlphaOption("output_font_name")` (pushed from the app's setting).
    func setOutputFontName(_ name: String) {
        outputFontName = name
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

    /// Set (or create) a variable in an explicit scope, marking the scope
    /// dirty so the host persists it. Distinct from the Lua-facing `setVar`,
    /// which always targets `currentVariableScope`: this is the host path the
    /// Variables editor uses to write any scope directly (#69).
    func setVariableValue(scope: String, name: String, value: String) {
        variables[scope, default: [:]][name] = value
        dirtyVariableScopes.insert(scope)
    }

    /// Delete a variable from an explicit scope, marking it dirty. The host
    /// path behind the Variables editor's delete (#69).
    func deleteVariableValue(scope: String, name: String) {
        variables[scope]?[name] = nil
        dirtyVariableScopes.insert(scope)
    }

    /// `proteles.varList([scope])` → a fresh Lua table `{name = value, …}` of a
    /// scope's variables, backing MUSHclient's `GetVariableList()` (current
    /// scope, when the arg is empty) and `GetPluginVariableList(id)` (the named
    /// plugin's scope). An unknown/empty scope yields an empty table — never
    /// nil — matching MUSHclient, where both calls always return a table.
    ///
    /// Built directly on the Lua stack and handed back through the registry-ref
    /// bridge (like ``jsonDecode``), since ``LuaValue`` has no table case. Runs
    /// inside `lua_pcall` on the executor, hence `nonisolated`.
    nonisolated func variableList(_ arguments: [LuaValue]) -> [LuaValue] {
        let requested = Self.argString(arguments, 0)
        let scope = requested.isEmpty ? currentVariableScope : requested
        let entries = variables[scope] ?? [:]
        lua_createtable(state, 0, Int32(entries.count))
        for (name, value) in entries {
            lua_pushstring(state, value)
            lua_setfield(state, -2, name)
        }
        let ref = luaL_ref(state, LUA_REGISTRYINDEX) // pops the table, stores it
        noteTransientRef(ref)
        return [.functionRef(ref)]
    }
}

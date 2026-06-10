import CLua
import Foundation

/// Per-plugin Lua environments (PLAN.md §7.3). MUSHclient runs each plugin in
/// its own Lua state; we have one shared state, so instead each plugin gets
/// its own *environment table* via `setfenv`. The env's metatable `__index`
/// falls back to the real globals (`_G`), so a plugin reads the shared shim
/// (`Send`, `Note`, `require`, …) and helper libraries normally, but anything
/// it *defines* (its functions, its `OnPluginBroadcast`, top-level state)
/// lands in its own table — isolated from other plugins.
///
/// The plugin's script, its lifecycle callbacks, and its trigger/alias/timer
/// scripts all run in this env (the host owner-routes them), so a plugin's
/// trigger can call functions the plugin defined.
public extension LuaRuntime {
    /// Create (or reset) the environment table for `pluginID`.
    func createPluginEnvironment(_ pluginID: String) {
        if let existing = pluginEnvs[pluginID] {
            luaL_unref(state, LUA_REGISTRYINDEX, existing)
        }
        lua_createtable(state, 0, 0) // [env]
        lua_createtable(state, 0, 1) // [env, mt]
        lua_pushvalue(state, LUA_GLOBALSINDEX) // [env, mt, _G]
        lua_setfield(state, -2, "__index") // mt.__index = _G; [env, mt]
        lua_setmetatable(state, -2) // setmetatable(env, mt); [env]
        pluginEnvs[pluginID] = luaL_ref(state, LUA_REGISTRYINDEX) // pops env
    }

    /// Drop every plugin environment (e.g. on `reload`).
    func clearPluginEnvironments() {
        for ref in pluginEnvs.values {
            luaL_unref(state, LUA_REGISTRYINDEX, ref)
        }
        pluginEnvs.removeAll()
    }

    /// Drop a *single* plugin's environment (e.g. when reloading just that
    /// plugin). Releases the registry ref so its globals/callbacks can't fire
    /// again; a subsequent ``createPluginEnvironment(_:)`` gives it a fresh one.
    func clearPluginEnvironment(_ pluginID: String) {
        if let ref = pluginEnvs.removeValue(forKey: pluginID) {
            luaL_unref(state, LUA_REGISTRYINDEX, ref)
        }
    }

    /// Run a plugin's `<script>` chunk in its environment, returning the
    /// effects it recorded. Errors surface as a red note.
    @discardableResult
    func loadPluginScript(_ source: String, pluginID: String) -> [ScriptEffect] {
        runInEnvironment(source, pluginID: pluginID, chunkName: pluginID, errorLabel: "Plugin script error")
    }

    /// Run an owned trigger/alias/timer script in the plugin's environment,
    /// with `matches`/`named` bound (in `_G`, reachable via the env's
    /// `__index`). Errors surface as a red note.
    @discardableResult
    func runPluginScript(
        _ script: String,
        pluginID: String,
        matches: [String] = [],
        named: [String: String] = [:],
        styles: [ScriptStyleRun] = []
    ) -> [ScriptEffect] {
        setMatchGlobals(matches, named)
        setStyleGlobal(styles)
        return runInEnvironment(script, pluginID: pluginID, chunkName: "script", errorLabel: "Script error")
    }

    /// Call a callback defined in the plugin's environment (lifecycle
    /// callbacks like `OnPluginInstall`/`OnPluginBroadcast`). A no-op when the
    /// plugin has no such function.
    @discardableResult
    func callPluginCallback(
        _ pluginID: String,
        _ name: String,
        _ arguments: [LuaValue] = []
    ) -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        // Bind the variable scope AND ambient context (GetPluginID/GetInfo(60)/…)
        // to THIS plugin for the duration of the call, then restore. Both are
        // process-global and were otherwise set only at load time (to whichever
        // plugin loaded last — e.g. dinv, armed, loads mid-session after leveldb),
        // so a lifecycle callback like OnPluginSaveState would persist into the
        // wrong plugin's variable bucket and read another plugin's identity/dir.
        let previousScope = currentVariableScope
        let previousContext = pluginContext
        currentVariableScope = pluginID
        if let context = pluginContexts[pluginID] { pluginContext = context }
        defer {
            currentVariableScope = previousScope
            pluginContext = previousContext
            releaseTransientRefs()
        }
        guard let envRef = pluginEnvs[pluginID] else { return effects }
        lua_rawgeti(state, LUA_REGISTRYINDEX, envRef) // [env]
        lua_getfield(state, -1, name) // [env, fn]
        lua_remove(state, -2) // [fn]
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            clua_pop(state, 1)
            return effects
        }
        for argument in arguments {
            luaPushValue(state, argument)
        }
        if lua_pcall(state, Int32(arguments.count), 0, 0) != 0 {
            effects.append(contentsOf: scriptErrorEffects(
                "Lua callback error in \(name): \(Self.popMessage(state))", pluginID: pluginID
            ))
        }
        return effects
    }

    /// Call a plugin's `OnPluginSend(text)` and capture its return. MUSHclient
    /// semantics: returning **false blocks** the send; anything else (true, nil,
    /// no return) allows it. Returns the recorded effects (the plugin may
    /// re-send/register) plus the allow decision. Missing callback or error ⇒
    /// allow (never silently swallow a user's command).
    func callPluginSend(_ pluginID: String, _ text: String) -> (effects: [ScriptEffect], allow: Bool) {
        effects.removeAll(keepingCapacity: true)
        // Scope Get/SetVariable to THIS plugin for the call (see callPluginCallback).
        let previousScope = currentVariableScope
        let previousContext = pluginContext
        currentVariableScope = pluginID
        if let context = pluginContexts[pluginID] { pluginContext = context }
        defer {
            currentVariableScope = previousScope
            pluginContext = previousContext
            releaseTransientRefs()
        }
        guard let envRef = pluginEnvs[pluginID] else { return (effects, true) }
        lua_rawgeti(state, LUA_REGISTRYINDEX, envRef) // [env]
        lua_getfield(state, -1, "OnPluginSend") // [env, fn]
        lua_remove(state, -2) // [fn]
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            clua_pop(state, 1)
            return (effects, true)
        }
        luaPushValue(state, .string(text))
        if lua_pcall(state, 1, 1, 0) != 0 {
            effects.append(contentsOf: scriptErrorEffects(
                "Lua callback error in OnPluginSend: \(Self.popMessage(state))", pluginID: pluginID
            ))
            return (effects, true)
        }
        // Only an explicit `false` blocks; a nil/absent result allows.
        let allow = lua_type(state, -1) == LUA_TNIL || lua_toboolean(state, -1) != 0
        clua_pop(state, 1)
        return (effects, allow)
    }

    // MARK: - Private

    /// Compile `source`, set its environment to `pluginID`'s env, and run it.
    private func runInEnvironment(
        _ source: String,
        pluginID: String,
        chunkName: String,
        errorLabel: String
    ) -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        // Owned trigger/alias/timer scripts read/write THIS plugin's variables
        // (see callPluginCallback) — scope for the run, then restore.
        let previousScope = currentVariableScope
        let previousContext = pluginContext
        currentVariableScope = pluginID
        if let context = pluginContexts[pluginID] { pluginContext = context }
        defer {
            currentVariableScope = previousScope
            pluginContext = previousContext
            releaseTransientRefs()
        }
        guard let envRef = pluginEnvs[pluginID] else { return effects }
        guard Self.loadBuffer(state, source, name: "=" + chunkName) == 0 else {
            effects.append(contentsOf: scriptErrorEffects(
                "Lua compile error: \(Self.popMessage(state))", pluginID: pluginID
            ))
            return effects
        }
        lua_rawgeti(state, LUA_REGISTRYINDEX, envRef) // [chunk, env]
        lua_setfenv(state, -2) // set chunk's env; pops env; [chunk]
        if lua_pcall(state, 0, 0, 0) != 0 {
            effects.append(contentsOf: scriptErrorEffects(
                "\(errorLabel): \(Self.popMessage(state))", pluginID: pluginID
            ))
        }
        return effects
    }

    /// A script error as paired effects: the red scrollback note (existing
    /// behaviour) plus a `.diagnostic` for the Lua Console, attributed to the
    /// plugin's display name (falling back to its id).
    func scriptErrorEffects(_ text: String, pluginID: String?) -> [ScriptEffect] {
        let source = pluginID.map { id in
            let name = pluginContexts[id]?.pluginName ?? ""
            return name.isEmpty ? id : name
        }
        let diagnostic = ScriptEffect.diagnostic(source: source, message: text)
        guard errorNotesVisible else { return [diagnostic] }
        return [
            .note(text: text, foreground: "red", background: nil),
            diagnostic
        ]
    }
}

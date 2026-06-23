import CLua
import Foundation

extension LuaRuntime {
    /// Evaluate one-off **console** input (the `/lua …` command, #41) on the live
    /// user runtime and return the side effects to surface.
    ///
    /// Behaviour mirrors a REPL: the input is compiled as an *expression* first
    /// (`return <code>`) so a value echoes (`/lua 2+2` → `= 4`,
    /// `/lua Button.list()` → its result); if that doesn't *compile*, it's run as
    /// *statements* (so `x = 5`, loops, multi-statement input work). The decision
    /// is by compilation only — never by trial execution — so a command with side
    /// effects (`Button.add(...)`) runs exactly once. `print`/`Note` output is
    /// captured as effects (the compat shim routes them through `proteles.*`), and
    /// any compile/runtime error becomes a single red note. Never throws.
    ///
    /// Runs in the `_user` scope/context (like a user alias) by default, so it
    /// pokes at the same globals the user's own scripts see — or, when
    /// `pluginID` names a loaded shim plugin, inside that plugin's sandbox
    /// environment + variable scope (the console's environment picker), so
    /// you can inspect/poke a plugin's locals-turned-globals directly.
    public func evaluateConsole(_ code: String, pluginID: String? = nil) -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        defer { releaseTransientRefs() }
        let previousScope = currentVariableScope
        let previousContext = pluginContext
        if let pluginID {
            guard pluginEnvs[pluginID] != nil else {
                return [Self.consoleNote("error: no loaded plugin environment '\(pluginID)'", color: "red")]
            }
            currentVariableScope = pluginID
            if let context = pluginContexts[pluginID] { pluginContext = context }
        } else {
            currentVariableScope = "_user"
            pluginContext = userPluginContext()
        }
        defer { currentVariableScope = previousScope; pluginContext = previousContext }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Self.consoleNote("usage: /lua <code>  —  e.g. /lua Button.list()", color: "yellow")]
        }

        let base = lua_gettop(state)
        var isExpression = true
        if luaL_loadstring(state, "return " + trimmed) != 0 {
            clua_pop(state, 1) // discard the expression-form compile error
            isExpression = false
            if luaL_loadstring(state, trimmed) != 0 {
                effects.append(Self.consoleNote("error: \(popError())", color: "red"))
                return effects
            }
        }
        // Run inside the picked plugin's sandbox env (its `__index` still
        // reaches `_G`, so shared helpers keep working).
        if let pluginID, let envRef = pluginEnvs[pluginID] {
            lua_rawgeti(state, LUA_REGISTRYINDEX, envRef) // [chunk, env]
            lua_setfenv(state, -2) // [chunk]
        }

        clua_install_timeout(state, executionTimeout.inSeconds, Self.hookInstructionInterval)
        defer { clua_clear_timeout(state) }
        if protectedCall(nargs: 0, nresults: LUA_MULTRET) != 0 {
            let message = popError()
            let text = message.contains("proteles:timeout") ? "execution timed out" : message
            effects.append(Self.consoleNote("error: \(text)", color: "red"))
            return effects
        }

        // Echo return value(s) for the expression form (statements return none).
        if isExpression {
            let count = Int(lua_gettop(state) - base)
            if count > 0 {
                let parts = (0..<count).map { consoleStringify(base + Int32($0) + 1) }
                effects.append(Self.consoleNote("= " + parts.joined(separator: ",  "), color: "cyan"))
            }
        }
        lua_settop(state, base)
        return effects
    }

    /// `tostring(value-at-index)` via Lua's global `tostring`, so tables and
    /// `__tostring` metamethods render the way they do in-game. Falls back to a
    /// raw read (then `?`) if `tostring` itself errors.
    private func consoleStringify(_ index: Int32) -> String {
        clua_getglobal(state, "tostring")
        lua_pushvalue(state, index)
        if lua_pcall(state, 1, 1, 0) != 0 {
            clua_pop(state, 1)
            if let raw = clua_tostring(state, index) { return String(cString: raw) }
            return "?"
        }
        defer { clua_pop(state, 1) }
        if let rendered = clua_tostring(state, -1) { return String(cString: rendered) }
        return "?"
    }

    /// A console line, prefixed `lua:` so console output is visually distinct
    /// from MUD text and obviously came from `/lua`.
    static func consoleNote(_ text: String, color: String) -> ScriptEffect {
        .note(text: "lua: \(text)", foreground: color, background: nil)
    }
}

public extension LuaRuntime {
    /// A loaded plugin's display name for the console's environment picker
    /// (its `<plugin name=…>`), falling back to the id.
    func pluginDisplayName(_ pluginID: String) -> String {
        let name = pluginContexts[pluginID]?.pluginName ?? ""
        return name.isEmpty ? pluginID : name
    }
}

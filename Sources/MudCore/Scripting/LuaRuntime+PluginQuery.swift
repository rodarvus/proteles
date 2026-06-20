import CLua
import Foundation

/// Plugin-management world queries: `GetPluginList` (the loaded-plugin ids) and
/// `PluginSupports` (whether a plugin exposes a callable routine). Both answer
/// synchronously from the runtime's own plugin registries — no actor hop —
/// matching how the trigger/alias/timer introspection queries work.
extension LuaRuntime {
    nonisolated func pluginQueryValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .pluginList:
            [pushNameArray(loadedPluginIDList())]
        case .pluginSupports:
            [.boolean(pluginEnvHasFunction(Self.argString(arguments, 0), Self.argString(arguments, 1)))]
        default:
            [.nil]
        }
    }

    /// The ids `GetPluginList` reports: every loaded shim-plugin env, the
    /// natively bridged ids (mapper/S&D/GMCP/chat — which `IsPluginInstalled`
    /// also treats as installed), and the caller itself. Deduped and sorted for
    /// stable iteration. Never empty (the caller is always present), so the
    /// `for _, id in ipairs(GetPluginList())` idiom can't hit `ipairs(nil)`.
    private nonisolated func loadedPluginIDList() -> [String] {
        var ids = Set(pluginEnvs.keys)
        ids.formUnion(bridgedPluginIDs)
        ids.insert(pluginContext.pluginID)
        return ids.filter { !$0.isEmpty }.sorted()
    }

    /// Whether plugin `id`'s environment defines a global function `routine`
    /// (MUSHclient `PluginSupports`). Bridged native plugins aren't shim Lua
    /// envs, so their routines aren't enumerable here → `false` (the shim maps
    /// that to `eNoSuchRoutine`).
    private nonisolated func pluginEnvHasFunction(_ id: String, _ routine: String) -> Bool {
        guard !routine.isEmpty, let envRef = pluginEnvs[id] else { return false }
        lua_rawgeti(state, LUA_REGISTRYINDEX, envRef) // [env]
        lua_getfield(state, -1, routine) // [env, env[routine]]
        let isFunction = lua_type(state, -1) == LUA_TFUNCTION
        clua_pop(state, 2)
        return isFunction
    }
}

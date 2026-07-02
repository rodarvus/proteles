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
        case .pluginInfo:
            [pluginInfoValue(pluginID: Self.argString(arguments, 0), code: Int(Self.argDouble(arguments, 1)))]
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

    private nonisolated func pluginInfoValue(pluginID id: String, code: Int) -> LuaValue {
        let resolvedID = id.isEmpty ? pluginContext.pluginID : id
        if let context = loadedPluginContext(for: resolvedID) {
            return pluginInfoValue(context: context, code: code)
        }
        guard bridgedPluginIDs.contains(resolvedID) else { return .nil }
        switch code {
        case 1: return .string(bridgedPluginName(resolvedID))
        case 17: return .boolean(true)
        default: return .nil
        }
    }

    private nonisolated func loadedPluginContext(for id: String) -> PluginContext? {
        if id == pluginContext.pluginID { return pluginContext }
        guard pluginEnvs[id] != nil else { return nil }
        return pluginContexts[id]
    }

    private nonisolated func pluginInfoValue(context: PluginContext, code: Int) -> LuaValue {
        if code == 17 { return .boolean(true) }
        if code == 3 { return .string(context.pluginDescription) }
        if code == 6 { return context.pluginSourceFile.isEmpty ? .nil : .string(context.pluginSourceFile) }
        if code == 20 {
            guard let value = context.info(60) else { return .nil }
            if case .text(let text) = value { return .string(text) }
            return .nil
        }
        guard let value = context.info(code) else { return .nil }
        switch value {
        case .text(let text): return .string(text)
        case .number(let number): return .number(number)
        case .flag(let flag): return .boolean(flag)
        }
    }

    private nonisolated func bridgedPluginName(_ id: String) -> String {
        switch id {
        case "3e7dedbe37e44942dd46d264": "Aardwolf GMCP Handler"
        case "b555825a4a5700c35fa80780": "Aardwolf Chat Capture"
        case "b6eae87ccedd84f510b74714": "Aardwolf Mapper"
        case "462b665ecb569efbf261422f": "Aardwolf Miniwindow Z-Order Monitor"
        case "30000000537461726C696E67": "Search and Destroy"
        default: ""
        }
    }
}

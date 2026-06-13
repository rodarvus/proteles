import Foundation

/// Miniwindow support on the script engine: the generalised "call a named
/// function in plugin N's environment" the hotspot dispatch needs (a `Canvas`
/// gesture → the plugin's registered Lua callback). Split from `ScriptEngine`
/// for the file-length budget. See `docs/plans/MINIWINDOW_FEASIBILITY.md`.
public extension ScriptEngine {
    /// Invoke `name` in `pluginID`'s environment with `arguments`, returning the
    /// effects it recorded (including any window redraw the callback issued).
    @discardableResult
    func callPluginFunction(
        _ pluginID: String,
        _ name: String,
        _ arguments: [LuaValue] = []
    ) async -> [ScriptEffect] {
        await runtime.callPluginCallback(pluginID, name, arguments)
    }
}

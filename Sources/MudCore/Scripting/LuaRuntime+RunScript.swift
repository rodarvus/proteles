import Foundation

public extension LuaRuntime {
    /// Like ``runScript(_:matches:named:styles:)`` but bound to `pluginID`'s
    /// registered context + variable scope, running in the MAIN environment
    /// (not a sandboxed plugin env). The S&D host's firing path (D-108): its
    /// whole runtime is one plugin whose code lives in the global env, so a
    /// trigger script must see S&D's `GetInfo` paths — the `_user`/`.default`
    /// reset in the generic `runScript` blanked `GetInfo(66)` mid-firing,
    /// every fire-time `sqlite3.open` built a relative path the sqlite
    /// sandbox denied, and S&D's `area_index_line` died on its first
    /// statement → an empty area index → every room-campaign target
    /// "unknown" (live report, 2026-06-10).
    @discardableResult
    func runScript(
        _ script: String,
        asPlugin pluginID: String,
        matches captures: [String] = [],
        named: [String: String] = [:],
        styles: [ScriptStyleRun] = []
    ) throws -> [ScriptEffect] {
        let previousScope = currentVariableScope
        let previousContext = pluginContext
        currentVariableScope = pluginID
        if let context = pluginContexts[pluginID] { pluginContext = context }
        defer { currentVariableScope = previousScope; pluginContext = previousContext }
        setMatchGlobals(captures, named)
        setStyleGlobal(styles)
        return try run(script)
    }
}

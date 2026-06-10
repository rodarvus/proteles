public extension ScriptEngine {
    /// Evaluate one-off **console** input (the `/lua …` command, #41) on the live
    /// user runtime, returning the effects to surface (captured `print`/`Note`
    /// output, an `= value` echo for expressions, or a single red error note).
    /// See ``LuaRuntime/evaluateConsole(_:)``.
    @discardableResult
    func evaluateConsole(_ code: String) async -> [ScriptEffect] {
        await runtime.evaluateConsole(code)
    }
}

public extension ScriptEngine {
    /// Mark a natively-bridged MUSHclient plugin id present/absent for the
    /// shim's `IsPluginInstalled` (the session calls this as the mapper / S&D
    /// host attach or a world reload drops them).
    func setBridgedPlugin(_ id: String, installed: Bool) async {
        await runtime.setBridgedPlugin(id, installed: installed)
    }
}

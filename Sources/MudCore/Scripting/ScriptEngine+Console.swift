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

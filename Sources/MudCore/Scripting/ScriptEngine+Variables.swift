import Foundation

/// Explicit-scope variable mutators for the Scripts window's Variables tab
/// (#69), forwarding to the underlying ``LuaRuntime``. Split from
/// ``ScriptEngine`` to keep that file within the 600-line budget. Distinct from
/// the Lua-facing `setVar`/`deleteVar` (which target `currentVariableScope`):
/// these write any scope directly and mark it dirty, so the session's
/// `persistVariablesIfDirty()` flushes the edit to the on-disk store.
public extension ScriptEngine {
    /// Set (or create) a variable in an explicit scope, marking it dirty.
    func setVariableValue(scope: String, name: String, value: String) async {
        await runtime.setVariableValue(scope: scope, name: name, value: value)
    }

    /// Delete a variable from an explicit scope, marking it dirty.
    func deleteVariableValue(scope: String, name: String) async {
        await runtime.deleteVariableValue(scope: scope, name: name)
    }
}

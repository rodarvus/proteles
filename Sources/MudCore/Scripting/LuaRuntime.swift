import CLua
import Foundation

/// Thin Swift actor over a vendored PUC-Rio Lua 5.1 interpreter
/// (`CLua`) — the foundation for triggers, aliases, timers, and the
/// `proteles.*` scripting API (PLAN.md §8.6, D-03).
///
/// One `lua_State` per runtime, owned and isolated by the actor so the
/// (non-reentrant) interpreter is only ever touched from one place.
///
/// **Not yet sandboxed.** This opens the full standard library for now;
/// the `_G` replacement / `io`/`os` restriction / instruction-count hook
/// (D-10) land in the next increment, before any untrusted script runs.
public actor LuaRuntime {
    public enum LuaError: Error, Equatable, Sendable {
        case initializationFailed
        /// The chunk failed to compile.
        case syntax(String)
        /// The chunk compiled but raised at runtime.
        case runtime(String)
        /// A result wasn't of the expected type.
        case typeMismatch(String)
    }

    /// Accessed only on the actor, except in `deinit` (which runs when no
    /// other reference survives) — hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) let state: OpaquePointer

    public init() throws {
        guard let state = luaL_newstate() else {
            throw LuaError.initializationFailed
        }
        self.state = state
        luaL_openlibs(state)
    }

    deinit {
        lua_close(state)
    }

    /// Execute a chunk for its side effects; results are discarded.
    public func run(_ script: String) throws {
        try load(script)
        try call(argumentCount: 0, resultCount: 0)
    }

    /// Evaluate an expression and return its numeric result.
    public func number(_ expression: String) throws -> Double {
        try evaluate(expression)
        defer { clua_pop(state, 1) }
        guard lua_isnumber(state, -1) != 0 else {
            throw LuaError.typeMismatch("expected a number from \(expression.debugDescription)")
        }
        return lua_tonumber(state, -1)
    }

    /// Evaluate an expression and return its string result. (Lua coerces
    /// numbers to strings, matching `tostring`.)
    public func string(_ expression: String) throws -> String {
        try evaluate(expression)
        defer { clua_pop(state, 1) }
        guard lua_isstring(state, -1) != 0, let cString = clua_tostring(state, -1) else {
            throw LuaError.typeMismatch("expected a string from \(expression.debugDescription)")
        }
        return String(cString: cString)
    }

    /// Evaluate an expression and return its boolean truthiness (Lua
    /// rules: everything except `false` and `nil` is true).
    public func boolean(_ expression: String) throws -> Bool {
        try evaluate(expression)
        defer { clua_pop(state, 1) }
        return lua_toboolean(state, -1) != 0
    }

    /// Set a global to a number.
    public func setGlobal(_ name: String, to value: Double) {
        lua_pushnumber(state, value)
        clua_setglobal(state, name)
    }

    /// Set a global to a string.
    public func setGlobal(_ name: String, to value: String) {
        lua_pushstring(state, value)
        clua_setglobal(state, name)
    }

    // MARK: - Private

    /// Compile + run `return <expression>`, leaving the single result on
    /// the stack for the caller to read and pop.
    private func evaluate(_ expression: String) throws {
        try load("return \(expression)")
        try call(argumentCount: 0, resultCount: 1)
    }

    private func load(_ script: String) throws {
        if luaL_loadstring(state, script) != 0 {
            throw LuaError.syntax(popError())
        }
    }

    private func call(argumentCount: Int32, resultCount: Int32) throws {
        if lua_pcall(state, argumentCount, resultCount, 0) != 0 {
            throw LuaError.runtime(popError())
        }
    }

    /// Pop the error object at the top of the stack as a String.
    private func popError() -> String {
        let message = clua_tostring(state, -1).map { String(cString: $0) } ?? "unknown Lua error"
        clua_pop(state, 1)
        return message
    }
}

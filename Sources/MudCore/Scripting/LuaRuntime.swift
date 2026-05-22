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
        /// The chunk ran longer than ``LuaRuntime/executionTimeout`` and
        /// was aborted (e.g. an accidental infinite loop).
        case timedOut
    }

    /// Wall-clock budget for a single ``run``/evaluation. A chunk that
    /// exceeds it is aborted with ``LuaError/timedOut``. `.zero` (or
    /// negative) disables the guard. Generous by default — trigger/alias
    /// actions should be near-instant.
    public var executionTimeout: Duration

    /// How often (in VM instructions) the timeout hook checks the clock.
    private static let hookInstructionInterval: Int32 = 1000

    /// Accessed only on the actor, except in `deinit` (which runs when no
    /// other reference survives) — hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) let state: OpaquePointer

    /// Create a runtime. When `sandboxed` (the default), the dangerous
    /// standard-library surface is removed before the runtime is usable —
    /// see ``sandboxScript``. Pass `false` only for fully-trusted internal
    /// scripts.
    public init(sandboxed: Bool = true, executionTimeout: Duration = .seconds(2)) throws {
        guard let state = luaL_newstate() else {
            throw LuaError.initializationFailed
        }
        self.state = state
        self.executionTimeout = executionTimeout
        luaL_openlibs(state)
        if sandboxed {
            try Self.applySandbox(to: state)
        }
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

    // MARK: - Sandbox

    /// First-pass sandbox (D-10): strip the standard-library surface that
    /// can touch the filesystem, run programs, load native code, or escape
    /// back to the removed libraries.
    ///
    /// Removed: `io`, `package` (and so `package.loaded`, a back-door to
    /// the removed libraries), `require`/`module`/`dofile`/`loadfile`/
    /// `loadstring`/`load`. `os` keeps only the clock/date helpers. `debug`
    /// keeps only `traceback` — dropping `getregistry`, the other recovery
    /// path to removed libraries. `math`/`string`/`table` stay intact.
    ///
    /// An instruction-count / wall-clock timeout hook (to stop runaway
    /// loops) is a separate follow-up.
    nonisolated static let sandboxScript = """
    io = nil
    package = nil
    require = nil
    module = nil
    dofile = nil
    loadfile = nil
    loadstring = nil
    load = nil
    local _os = os
    os = { time = _os.time, clock = _os.clock, date = _os.date, difftime = _os.difftime }
    local _debug = debug
    debug = { traceback = _debug.traceback }
    """

    /// Run the sandbox chunk directly on a freshly-opened state. Static so
    /// it's callable from the (nonisolated) initializer; it touches only
    /// the passed pointer, not the actor's isolated surface.
    private static func applySandbox(to state: OpaquePointer) throws {
        if luaL_loadstring(state, sandboxScript) != 0 {
            throw LuaError.syntax(popMessage(state))
        }
        if lua_pcall(state, 0, 0, 0) != 0 {
            throw LuaError.runtime(popMessage(state))
        }
    }

    /// Pop the top-of-stack error object as a String (state-only; shared
    /// by the initializer's sandbox path and the instance error path).
    private static func popMessage(_ state: OpaquePointer) -> String {
        let message = clua_tostring(state, -1).map { String(cString: $0) } ?? "unknown Lua error"
        clua_pop(state, 1)
        return message
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
        clua_install_timeout(state, executionTimeout.inSeconds, Self.hookInstructionInterval)
        defer { clua_clear_timeout(state) }
        if lua_pcall(state, argumentCount, resultCount, 0) != 0 {
            let message = popError()
            if message.contains("proteles:timeout") {
                throw LuaError.timedOut
            }
            throw LuaError.runtime(message)
        }
    }

    /// Pop the error object at the top of the stack as a String.
    private func popError() -> String {
        Self.popMessage(state)
    }
}

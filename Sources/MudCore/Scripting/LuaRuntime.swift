import CLua
import Foundation

// MARK: - Lua ↔ Swift bridge

/// Read the Lua value at `index` as a ``LuaValue`` (scalars only).
private func luaReadValue(_ state: OpaquePointer, _ index: Int32) -> LuaValue {
    switch lua_type(state, index) {
    case LUA_TBOOLEAN:
        .boolean(lua_toboolean(state, index) != 0)
    case LUA_TNUMBER:
        .number(lua_tonumber(state, index))
    case LUA_TSTRING:
        clua_tostring(state, index).map { .string(String(cString: $0)) } ?? .nil
    default:
        .nil
    }
}

/// Push a ``LuaValue`` onto the Lua stack. Module-internal so the compat-shim
/// extension can reuse it.
func luaPushValue(_ state: OpaquePointer, _ value: LuaValue) {
    switch value {
    case .nil: lua_pushnil(state)
    case .boolean(let flag): lua_pushboolean(state, flag ? 1 : 0)
    case .number(let number): lua_pushnumber(state, number)
    case .string(let text): lua_pushstring(state, text)
    case .functionRef(let ref): lua_rawgeti(state, LUA_REGISTRYINDEX, ref)
    }
}

/// Single C entry point for every registered host function. Upvalue 1 is
/// the owning ``LuaRuntime`` (lightuserdata); upvalue 2 is the host-function
/// id. Non-capturing, as `@convention(c)` requires — all context comes
/// from the upvalues. Runs synchronously inside `lua_pcall`, i.e. on the
/// owning actor's executor.
private let luaHostDispatch: @convention(c) (OpaquePointer?) -> Int32 = { statePointer in
    guard let state = statePointer,
          let runtimePointer = lua_touserdata(state, clua_upvalueindex(1))
    else {
        return 0
    }
    let runtime = Unmanaged<LuaRuntime>
        .fromOpaque(UnsafeRawPointer(runtimePointer))
        .takeUnretainedValue()
    let functionID = Int32(lua_tointeger(state, clua_upvalueindex(2)))

    var arguments: [LuaValue] = []
    let argumentCount = lua_gettop(state)
    if argumentCount > 0 {
        for index in 1...argumentCount {
            if lua_type(state, index) == LUA_TFUNCTION {
                lua_pushvalue(state, index)
                let ref = luaL_ref(state, LUA_REGISTRYINDEX)
                runtime.noteTransientRef(ref)
                arguments.append(.functionRef(ref))
            } else {
                arguments.append(luaReadValue(state, index))
            }
        }
    }

    let results = runtime.invokeHostFunction(id: functionID, arguments: arguments)
    for result in results {
        luaPushValue(state, result)
    }
    return Int32(results.count)
}

/// Thin Swift actor over a vendored PUC-Rio Lua 5.1 interpreter
/// (`CLua`) — the foundation for triggers, aliases, timers, and the
/// `proteles.*` scripting API (PLAN.md §8.6, D-03).
///
/// One `lua_State` per runtime, owned and isolated by the actor so the
/// (non-reentrant) interpreter is only ever touched from one place.
///
/// Sandboxed by default (D-10): the dangerous standard-library surface is
/// removed and a wall-clock timeout hook guards against runaway loops.
/// Scripts reach the host through the `proteles.*` table, whose calls
/// record ``ScriptEffect``s the host applies after the chunk returns.
public actor LuaRuntime {
    public enum LuaError: Error, Equatable, Sendable {
        case initializationFailed
        /// The chunk failed to compile.
        case syntax(String)
        /// The chunk compiled but raised at runtime.
        case runtime(String)
        /// A result wasn't of the expected type.
        case typeMismatch(String)
        /// The chunk exceeded ``LuaRuntime/executionTimeout`` and was aborted.
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
    /// other reference survives) — hence `nonisolated(unsafe)`. Module-internal
    /// (not `private`) so the GMCP projection extension can reach it.
    nonisolated(unsafe) let state: OpaquePointer

    /// Side effects recorded by `proteles.*` calls during the current run.
    /// `nonisolated(unsafe)`: the C dispatch appends synchronously inside
    /// `lua_pcall` (same actor executor) and `run` reads/clears it around that.
    nonisolated(unsafe) var effects: [ScriptEffect] = []

    /// The `proteles.*` functions exposed to scripts; the rawValue is the
    /// closure upvalue the C dispatcher routes on. Module-internal so the
    /// host-dispatch extension can switch on it.
    enum HostFunction: Int32 {
        case send = 1
        case sendNoEcho
        case execute
        case echo
        case note
        case onEvent
        case raiseEvent
        case onBroadcast
        case broadcast
        case export
        case call
        case getVar
        case setVar
        case deleteVar
        case info
        case pluginID
        case getPluginVar
        case compileChunk
        case moduleSource
        case sendGMCP
        case isConnected
        case jsonDecode
        case jsonEncode
        case echoAard, echoAnsi, simulate
        case colourNote, hyperlink, mapperCall, chatCapture
        case sqliteAllowed
        case publish
        case enableTrigger, enableTimer, enableGroup, doAfter
        case addTrigger, setTriggerGroup, enableAlias, removeTrigger, monotonic, addAlias
        case fileExists, makeDirectory, reloadPlugin
        case aardwolfTelnet
        case readFile, writeFile
        case dialog
    }

    /// Live connection state for `proteles.isConnected` (host-updated).
    nonisolated(unsafe) var connected = false

    /// App hook that fulfils a plugin's `utils.*` dialog synchronously (nil =
    /// dialogs degrade to a safe default). Set by ``setDialogProvider(_:)``.
    nonisolated(unsafe) var dialogProvider: ScriptDialogProvider?

    /// Module-loader state (see `LuaRuntime+Modules`): `require` libraries
    /// (name → source) and the dirs `require`/`dofile` may read.
    nonisolated(unsafe) var bundledModules: [String: String] = [:]
    nonisolated(unsafe) var moduleSearchPaths: [String] = []

    /// Ambient environment for `proteles.info`/`proteles.pluginID` (≈ MUSHclient
    /// `GetInfo`/`GetPluginID`). Loader-set per plugin; defaults to user scripts.
    nonisolated(unsafe) var pluginContext = PluginContext.default

    /// Per-plugin sandbox environments (plugin id → registry ref of an env
    /// table whose metatable `__index` falls back to `_G`). A plugin's script,
    /// callbacks, and trigger/alias/timer scripts run in its own env so two
    /// plugins can't clobber each other's globals. See `LuaRuntime+PluginEnvironments`.
    nonisolated(unsafe) var pluginEnvs: [String: Int32] = [:]

    /// Scoped string variables (`proteles.getVar`/`setVar`/`deleteVar`,
    /// ≈ MUSHclient `Get/SetVariable`). Keyed `scope → name → value`; the
    /// host sets ``currentVariableScope`` per plugin/script so each plugin's
    /// variables are isolated. Held in memory (so reads return synchronously
    /// inside the Lua dispatch) and synced to/from disk by the host around
    /// runs. `nonisolated(unsafe)` for the same reason as ``effects``.
    nonisolated(unsafe) var variables: [String: [String: String]] = [:]
    /// The scope `getVar`/`setVar`/`deleteVar` read and write. Defaults to a
    /// shared user scope; the plugin loader sets it per plugin id.
    nonisolated(unsafe) var currentVariableScope = "_user"
    /// Scopes whose variables changed since the last ``takeDirtyVariableScopes``,
    /// so the host knows what to persist.
    nonisolated(unsafe) var dirtyVariableScopes: Set<String> = []

    /// Event name → registry refs of registered handler functions.
    nonisolated(unsafe) var eventHandlers: [String: [Int32]] = [:]
    private nonisolated(unsafe) var broadcastHandlers: [Int32] = [] // `onBroadcast` handler refs
    /// Exported callable name → registry ref (for `call`).
    private nonisolated(unsafe) var exportedFunctions: [String: Int32] = [:]
    /// Function refs created this run that no handler/export claimed; freed at
    /// run end so transient callbacks don't leak registry slots.
    private nonisolated(unsafe) var transientRefs: [Int32] = []
    /// Directory `sqlite3.open`/file helpers may touch; `nil` = closed.
    nonisolated(unsafe) var sqliteDirectory: String?

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
        installProtelesAPI()
        installModuleLoader()
        installSQLite()
    }

    deinit {
        lua_close(state)
    }

    /// Execute a chunk and return the side effects its `proteles.*` calls
    /// recorded, in order. The host applies them.
    @discardableResult
    public func run(_ script: String) throws -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        defer { releaseTransientRefs() }
        try load(script)
        try call(argumentCount: 0, resultCount: 0)
        return effects
    }

    /// Run a chunk with trigger captures bound to globals first, returning
    /// the recorded effects. Sets `matches` (a table keyed `0…n`, where
    /// `matches[0]` is the whole match and `matches[i]` the i-th group) and
    /// `named` (named captures). Done in one isolated call so nothing
    /// interleaves between binding and running.
    @discardableResult
    public func runScript(
        _ script: String,
        matches captures: [String] = [],
        named: [String: String] = [:],
        styles: [ScriptStyleRun] = []
    ) throws -> [ScriptEffect] {
        setMatchGlobals(captures, named)
        setStyleGlobal(styles)
        return try run(script)
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
    /// Module-internal so the compat-shim extension can reuse it.
    static func popMessage(_ state: OpaquePointer) -> String {
        let message = clua_tostring(state, -1).map { String(cString: $0) } ?? "unknown Lua error"
        clua_pop(state, 1)
        return message
    }

    // MARK: - proteles.* host API

    /// Build the global `proteles` table, each entry a C closure carrying
    /// this runtime (lightuserdata) and a function id as upvalues.
    /// `nonisolated` so the initializer can call it; touches only `state`
    /// and `self`'s pointer.
    private nonisolated func installProtelesAPI() {
        lua_createtable(state, 0, 26)
        setHostFunction("send", .send)
        setHostFunction("sendNoEcho", .sendNoEcho)
        setHostFunction("execute", .execute)
        setHostFunction("echo", .echo)
        setHostFunction("note", .note)
        setHostFunction("onEvent", .onEvent)
        setHostFunction("raiseEvent", .raiseEvent)
        setHostFunction("onBroadcast", .onBroadcast)
        setHostFunction("broadcast", .broadcast)
        setHostFunction("export", .export)
        setHostFunction("aardwolfTelnet", .aardwolfTelnet)
        setHostFunction("readFile", .readFile)
        setHostFunction("writeFile", .writeFile)
        setHostFunction("dialog", .dialog)
        setHostFunction("call", .call)
        setHostFunction("getVar", .getVar)
        setHostFunction("setVar", .setVar)
        setHostFunction("deleteVar", .deleteVar)
        setHostFunction("info", .info)
        setHostFunction("pluginID", .pluginID)
        setHostFunction("getPluginVar", .getPluginVar)
        setHostFunction("__compile", .compileChunk)
        setHostFunction("__moduleSource", .moduleSource)
        setHostFunction("sendGMCP", .sendGMCP)
        setHostFunction("isConnected", .isConnected)
        setHostFunction("jsonDecode", .jsonDecode)
        setHostFunction("jsonEncode", .jsonEncode)
        setHostFunction("echoAard", .echoAard)
        setHostFunction("echoAnsi", .echoAnsi)
        setHostFunction("simulate", .simulate)
        setHostFunction("colourNote", .colourNote)
        setHostFunction("hyperlink", .hyperlink)
        setHostFunction("mapperCall", .mapperCall)
        setHostFunction("chatCapture", .chatCapture)
        setHostFunction("sqliteAllowed", .sqliteAllowed)
        setHostFunction("publish", .publish)
        setHostFunction("enableTrigger", .enableTrigger)
        setHostFunction("enableTimer", .enableTimer)
        setHostFunction("enableGroup", .enableGroup)
        setHostFunction("doAfter", .doAfter)
        setHostFunction("addTrigger", .addTrigger)
        setHostFunction("addAlias", .addAlias)
        setHostFunction("setTriggerGroup", .setTriggerGroup)
        setHostFunction("removeTrigger", .removeTrigger)
        setHostFunction("enableAlias", .enableAlias)
        setHostFunction("monotonic", .monotonic)
        setHostFunction("fileExists", .fileExists)
        setHostFunction("makeDirectory", .makeDirectory)
        setHostFunction("reloadPlugin", .reloadPlugin)
        lua_createtable(state, 0, 0) // `proteles.gmcp`: live GMCP view (applyGMCP fills it)
        lua_setfield(state, -2, "gmcp")
        clua_setglobal(state, "proteles")
    }

    /// Set `proteles[name]` (table on stack top) to a C closure routing to `id`.
    private nonisolated func setHostFunction(_ name: String, _ id: HostFunction) {
        lua_pushlightuserdata(state, Unmanaged.passUnretained(self).toOpaque())
        lua_pushinteger(state, lua_Integer(id.rawValue))
        lua_pushcclosure(state, luaHostDispatch, 2)
        lua_setfield(state, -2, name)
    }

    /// Invoked synchronously by ``luaHostDispatch`` when a `proteles.*` function
    /// is called from Lua; records the effect. `nonisolated` (reaching `effects`
    /// via `nonisolated(unsafe)`) since it runs inside `lua_pcall` on the executor.
    nonisolated func invokeHostFunction(id: Int32, arguments: [LuaValue]) -> [LuaValue] {
        guard let function = HostFunction(rawValue: id) else { return [] }
        switch function {
        case .send, .sendNoEcho, .execute, .echo, .note, .sendGMCP, .echoAard, .echoAnsi, .colourNote,
             .hyperlink, .mapperCall, .chatCapture, .publish, .enableTrigger, .enableTimer, .enableGroup,
             .doAfter, .addTrigger, .addAlias, .setTriggerGroup, .enableAlias, .reloadPlugin,
             .aardwolfTelnet:
            recordEffect(function, arguments)
            return []
        case .call:
            guard let ref = exportedFunctions[Self.argString(arguments, 0)] else { return [] }
            return invokeFunction(ref, payload: Array(arguments.dropFirst()))
        case .getVar, .setVar, .deleteVar, .getPluginVar:
            return accessVariable(function, arguments)
        case .compileChunk:
            return compileChunk(arguments)
        case .moduleSource:
            return moduleSourceValue(arguments)
        case .jsonDecode, .jsonEncode:
            return jsonValue(function, arguments)
        case .info, .pluginID, .isConnected, .sqliteAllowed, .monotonic, .fileExists, .makeDirectory,
             .readFile, .writeFile, .dialog:
            return queryValue(function, arguments)
        default:
            registerOrRaise(function, arguments)
            return []
        }
    }

    /// Scoped variable get/set/delete. `getVar` returns the stored string (or
    /// `nil` when unset, matching MUSHclient `GetVariable`); `setVar`/
    /// `deleteVar` mutate the current scope and mark it dirty.
    private nonisolated func accessVariable(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        let name = Self.argString(arguments, 0)
        switch function {
        case .getVar:
            return [variables[currentVariableScope]?[name].map { LuaValue.string($0) } ?? .nil]
        case .setVar:
            variables[currentVariableScope, default: [:]][name] = Self.argString(arguments, 1)
            dirtyVariableScopes.insert(currentVariableScope)
        case .deleteVar:
            variables[currentVariableScope]?[name] = nil
            dirtyVariableScopes.insert(currentVariableScope)
        case .getPluginVar:
            // arg0 is the target scope (plugin id), arg1 the variable name.
            return [variables[name]?[Self.argString(arguments, 1)].map { LuaValue.string($0) } ?? .nil]
        default:
            break
        }
        return []
    }

    /// The event-bus / RPC registration & firing functions (no return value).
    private nonisolated func registerOrRaise(_ function: HostFunction, _ arguments: [LuaValue]) {
        switch function {
        case .onEvent:
            if let ref = Self.argFunctionRef(arguments, 1) {
                eventHandlers[Self.argString(arguments, 0), default: []].append(claim(ref))
            }
        case .raiseEvent:
            invokeHandlers(
                eventHandlers[Self.argString(arguments, 0)] ?? [],
                payload: Array(arguments.dropFirst())
            )
        case .onBroadcast:
            if let ref = Self.argFunctionRef(arguments, 0) {
                broadcastHandlers.append(claim(ref))
            }
        case .broadcast:
            invokeHandlers(broadcastHandlers, payload: arguments)
        case .export:
            if let ref = Self.argFunctionRef(arguments, 1) {
                let name = Self.argString(arguments, 0)
                if let previous = exportedFunctions[name] { luaL_unref(state, LUA_REGISTRYINDEX, previous) }
                exportedFunctions[name] = claim(ref)
            }
        default: break
        }
    }

    // MARK: - Calling Lua from Swift (event bus / RPC)

    /// Record a function ref that will be freed at run-end unless claimed.
    nonisolated func noteTransientRef(_ ref: Int32) {
        transientRefs.append(ref)
    }

    /// Mark a transient ref as owned (stored long-term), so it isn't freed
    /// at run-end. Returns the same ref for convenience.
    private nonisolated func claim(_ ref: Int32) -> Int32 {
        transientRefs.removeAll { $0 == ref }
        return ref
    }

    /// Free every still-unclaimed function ref created during this run.
    nonisolated func releaseTransientRefs() {
        for ref in transientRefs {
            luaL_unref(state, LUA_REGISTRYINDEX, ref)
        }
        transientRefs.removeAll(keepingCapacity: true)
    }

    /// Call each handler ref with `payload`, discarding results. Handler
    /// errors are surfaced as a red note rather than aborting the caller.
    nonisolated func invokeHandlers(_ refs: [Int32], payload: [LuaValue]) {
        for ref in refs {
            lua_rawgeti(state, LUA_REGISTRYINDEX, ref)
            for value in payload {
                luaPushValue(state, value)
            }
            if lua_pcall(state, Int32(payload.count), 0, 0) != 0 {
                effects.append(.note(
                    text: "Lua event error: \(Self.popMessage(state))",
                    foreground: "red",
                    background: nil
                ))
            }
        }
    }

    /// Call an exported function ref with `payload`, returning its results.
    private nonisolated func invokeFunction(_ ref: Int32, payload: [LuaValue]) -> [LuaValue] {
        let base = lua_gettop(state)
        lua_rawgeti(state, LUA_REGISTRYINDEX, ref)
        for value in payload {
            luaPushValue(state, value)
        }
        if lua_pcall(state, Int32(payload.count), LUA_MULTRET, 0) != 0 {
            effects.append(.note(
                text: "Lua call error: \(Self.popMessage(state))",
                foreground: "red",
                background: nil
            ))
            lua_settop(state, base)
            return []
        }
        let resultCount = lua_gettop(state) - base
        var results: [LuaValue] = []
        if resultCount > 0 {
            for index in (base + 1)...(base + resultCount) {
                results.append(luaReadValue(state, index))
            }
        }
        lua_settop(state, base)
        return results
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

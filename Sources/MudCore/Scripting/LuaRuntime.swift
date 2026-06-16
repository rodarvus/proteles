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
/// `proteles.*` scripting API (ARCHITECTURE.md §8.6, D-03).
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
    static let hookInstructionInterval: Int32 = 1000

    /// Accessed only on the actor, except in `deinit` (which runs when no
    /// other reference survives) — hence `nonisolated(unsafe)`. Module-internal
    /// (not `private`) so the GMCP projection extension can reach it.
    nonisolated(unsafe) let state: OpaquePointer

    /// Side effects recorded by `proteles.*` calls during the current run.
    /// `nonisolated(unsafe)`: the C dispatch appends synchronously inside
    /// `lua_pcall` (same actor executor) and `run` reads/clears it around that.
    nonisolated(unsafe) var effects: [ScriptEffect] = []

    // `HostFunction` (the `proteles.*` dispatch enum) lives in
    // `LuaRuntime+HostFunction.swift` — the case list keeps growing.

    /// Live connection state for `proteles.isConnected` (host-updated).
    nonisolated(unsafe) var connected = false

    /// App hook that fulfils a plugin's `utils.*` dialog synchronously (nil =
    /// dialogs degrade to a safe default). Set by ``setDialogProvider(_:)``.
    nonisolated(unsafe) var dialogProvider: ScriptDialogProvider?

    /// App hook for `GetClipboard`/`SetClipboard` (nil = "" / no-op). Set by
    /// ``setClipboardProvider(_:)``.
    nonisolated(unsafe) var clipboardProvider: ClipboardProvider?

    /// App hook that registers a plugin's `Accelerator`/`AcceleratorTo` keybind
    /// into the live MacroEngine (nil = accelerators are inert). Set by
    /// ``setAcceleratorRegistrar(_:)``.
    nonisolated(unsafe) var acceleratorRegistrar: (@Sendable (Macro) -> Void)?

    /// Module-loader state (see `LuaRuntime+Modules`): `require` libraries
    /// (name → source) and the dirs `require`/`dofile` may read.
    nonisolated(unsafe) var bundledModules: [String: String] = [:]
    nonisolated(unsafe) var moduleSearchPaths: [String] = []

    /// Ambient `proteles.info`/`pluginID` (≈ `GetInfo`/`GetPluginID`), bound to the
    /// *executing* plugin per run via ``pluginContexts`` (see PluginEnvironments).
    nonisolated(unsafe) var pluginContext = PluginContext.default
    /// Per-plugin contexts (id → context), so a run re-enters the right ambient
    /// regardless of load order. Set by ``setPluginContext``.
    nonisolated(unsafe) var pluginContexts: [String: PluginContext] = [:]

    /// MUSHclient plugin ids whose behaviour Proteles provides NATIVELY, so the
    /// shim's `IsPluginInstalled` answers true and plugins gate features on
    /// them (the user plugin's campaign mode checks for S&D this way). The
    /// GMCP handler + chat capture bridges are unconditional; the session adds
    /// the mapper/S&D ids when those hosts attach.
    nonisolated(unsafe) var bridgedPluginIDs: Set<String> = [
        "3e7dedbe37e44942dd46d264", // aard GMCP handler (gmcpval bridge)
        "b555825a4a5700c35fa80780" // chat capture (storeFromOutside bridge)
    ]

    /// Live output-view pixel size, answered for `GetInfo(280/281)` (#30). Pushed
    /// from the app as the window resizes; defaults to MUSHclient's classic
    /// 800×600 so a plugin reading geometry before the app reports a size still
    /// gets a sane value.
    nonisolated(unsafe) var outputPixelWidth = 800
    nonisolated(unsafe) var outputPixelHeight = 600

    /// Per-character `~/Documents/Proteles/Databases/<character>/` (trailing
    /// slash), surfaced to plugins as `proteles.databaseDir()` so a plugin can
    /// keep its DB flat in the shared Databases tree (#43/#44). Empty until the
    /// session knows the character. Set via ``setDatabasesDirectory(_:)``.
    nonisolated(unsafe) var databasesDirectory = ""

    /// Whether script errors ALSO surface as red scrollback notes (the
    /// paired `.diagnostic` always reaches the Lua Console regardless) —
    /// Settings ▸ Input ▸ Scripting (#16). Default on.
    nonisolated(unsafe) var errorNotesVisible = true

    /// Per-plugin sandbox environments (plugin id → registry ref of an env table
    /// whose `__index` falls back to `_G`), so plugins can't clobber each other's
    /// globals. See `LuaRuntime+PluginEnvironments`.
    nonisolated(unsafe) var pluginEnvs: [String: Int32] = [:]

    /// Scoped string variables (`getVar`/`setVar`, ≈ `Get/SetVariable`), keyed
    /// `scope → name → value`, isolated per plugin via ``currentVariableScope``.
    nonisolated(unsafe) var variables: [String: [String: String]] = [:]
    /// The scope `getVar`/`setVar`/`deleteVar` read/write — bound to the executing
    /// plugin per run (`_user` default).
    nonisolated(unsafe) var currentVariableScope = "_user"
    /// Scopes whose variables changed since the last ``takeDirtyVariableScopes``.
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

    /// Mapper-DB merge state (D-111); set via `setMapperOverlay`, consumed by
    /// `mapperMergeSQL` (full rationale there). Both nil ⇒ no merge.
    nonisolated(unsafe) var mapperSharedDBPath: String?
    nonisolated(unsafe) var mapperOverlayPath: String?

    /// Pending async HTTP callbacks by request id (claimed refs, freed on
    /// completion — see `LuaRuntime+HTTP`); `nextHTTPRequestID` keys them.
    nonisolated(unsafe) var pendingHTTP: [Int: (callback: Int32?, onTimeout: Int32?)] = [:]
    nonisolated(unsafe) var nextHTTPRequestID = 0

    /// Live miniwindow scenes by name (see `LuaRuntime+MiniWindow`). Persisted
    /// across runs — geometry/flags/fonts survive between draw passes — and
    /// flushed to `.updateMiniWindow` effects at the end of each run/callback.
    nonisolated(unsafe) var miniWindows: [String: MiniWindowScene] = [:]
    /// Windows whose scene changed this run; flushed (one effect each) at run end.
    nonisolated(unsafe) var miniWindowsDirty: Set<String> = []
    /// Windows whose current frame has begun this run — the first draw/hotspot
    /// op of a run clears the prior frame's commands/hotspots, so a re-draw pass
    /// replaces wholesale (one `.updateMiniWindow` == one frame), bounding growth.
    nonisolated(unsafe) var miniWindowFramePainted: Set<String> = []

    /// Create a runtime. When `sandboxed` (the default), the dangerous
    /// standard-library surface is removed before use (see ``sandboxScript``);
    /// pass `false` only for fully-trusted internal scripts.
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

    /// Execute a chunk and return the recorded `proteles.*` side effects, in order.
    @discardableResult
    public func run(_ script: String) throws -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        beginMiniWindowPass()
        defer { releaseTransientRefs() }
        try load(script)
        try call(argumentCount: 0, resultCount: 0)
        flushMiniWindows()
        return effects
    }

    /// Run a chunk with trigger captures bound to globals first, returning the
    /// recorded effects. Sets `matches` (`matches[0]` = whole match, `matches[i]`
    /// = i-th group) and `named` (named captures), isolated so nothing interleaves.
    @discardableResult
    public func runScript(
        _ script: String,
        matches captures: [String] = [],
        named: [String: String] = [:],
        styles: [ScriptStyleRun] = []
    ) throws -> [ScriptEffect] {
        // User scripts use the default `_user` variable scope + ambient context;
        // set + restore both so a prior plugin run's id can't divert user
        // Get/SetVariable into a plugin's bucket or report a plugin's identity.
        let previousScope = currentVariableScope
        let previousContext = pluginContext
        currentVariableScope = "_user"
        pluginContext = .default
        defer { currentVariableScope = previousScope; pluginContext = previousContext }
        setMatchGlobals(captures, named)
        setStyleGlobal(styles)
        return try run(script)
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

    /// Run the sandbox chunk directly on a freshly-opened state. Static so it's
    /// callable from the (nonisolated) initializer; touches only the pointer.
    private static func applySandbox(to state: OpaquePointer) throws {
        if luaL_loadstring(state, sandboxScript) != 0 {
            throw LuaError.syntax(popMessage(state))
        }
        if lua_pcall(state, 0, 0, 0) != 0 {
            throw LuaError.runtime(popMessage(state))
        }
    }

    /// Pop the top-of-stack error object as a String (state-only; shared by the
    /// initializer's sandbox path + the instance error path; module-internal).
    static func popMessage(_ state: OpaquePointer) -> String {
        let message = clua_tostring(state, -1).map { String(cString: $0) } ?? "unknown Lua error"
        clua_pop(state, 1)
        return message
    }

    // MARK: - proteles.* host API

    /// Build the global `proteles` table, each entry a C closure carrying this
    /// runtime (lightuserdata) + a function id as upvalues. `nonisolated`.
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
        setHostFunction("accelerator", .accelerator)
        setHostFunction("__http", .http)
        setHostFunction("call", .call)
        setHostFunction("getVar", .getVar)
        setHostFunction("setVar", .setVar)
        setHostFunction("deleteVar", .deleteVar)
        setHostFunction("info", .info)
        setHostFunction("pluginID", .pluginID)
        setHostFunction("getPluginVar", .getPluginVar)
        setHostFunction("varList", .varList)
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
        setHostFunction("isPluginInstalled", .isPluginInstalled)
        setHostFunction("sndCall", .sndCall)
        setHostFunction("sqliteAllowed", .sqliteAllowed)
        setHostFunction("mapperMergeSQL", .mapperMergeSQL)
        setHostFunction("publish", .publish)
        installProtelesAPIAutomation()
    }

    /// Second half of ``installProtelesAPI`` (split to stay within the
    /// function-length budget). The `proteles` table is still on the Lua stack
    /// top, so registration continues against it.
    private nonisolated func installProtelesAPIAutomation() {
        setHostFunction("enableTrigger", .enableTrigger)
        setHostFunction("enableTimer", .enableTimer)
        setHostFunction("enableGroup", .enableGroup)
        setHostFunction("doAfter", .doAfter)
        setHostFunction("addTrigger", .addTrigger)
        setHostFunction("addAlias", .addAlias)
        setHostFunction("setTriggerGroup", .setTriggerGroup)
        setHostFunction("setTriggerOption", .setTriggerOption)
        setHostFunction("notify", .notify)
        setHostFunction("button", .button)
        setHostFunction("removeTrigger", .removeTrigger)
        setHostFunction("enableAlias", .enableAlias)
        setHostFunction("monotonic", .monotonic)
        setHostFunction("fileExists", .fileExists)
        setHostFunction("makeDirectory", .makeDirectory)
        setHostFunction("reloadPlugin", .reloadPlugin)
        setHostFunction("clipboardGet", .clipboardGet)
        setHostFunction("clipboardSet", .clipboardSet)
        setHostFunction("databaseDir", .databaseDir)
        setHostFunction("playSound", .playSound)
        setHostFunction("speak", .speak)
        installProtelesAPIMiniWindow()
        lua_createtable(state, 0, 0) // `proteles.gmcp`: live GMCP view (applyGMCP fills it)
        lua_setfield(state, -2, "gmcp")
        clua_setglobal(state, "proteles")
    }

    /// Set `proteles[name]` (table on stack top) to a C closure routing to `id`.
    /// Module-internal so the miniwindow registration extension can reuse it.
    nonisolated func setHostFunction(_ name: String, _ id: HostFunction) {
        lua_pushlightuserdata(state, Unmanaged.passUnretained(self).toOpaque())
        lua_pushinteger(state, lua_Integer(id.rawValue))
        lua_pushcclosure(state, luaHostDispatch, 2)
        lua_setfield(state, -2, name)
    }

    /// Invoked synchronously by ``luaHostDispatch`` when a `proteles.*` function
    /// is called from Lua; records the effect. `nonisolated` since it runs inside
    /// `lua_pcall` on the executor (reaching `effects` via `nonisolated(unsafe)`).
    nonisolated func invokeHostFunction(id: Int32, arguments: [LuaValue]) -> [LuaValue] {
        guard let function = HostFunction(rawValue: id) else { return [] }
        switch function {
        case .send, .sendNoEcho, .execute, .echo, .note, .sendGMCP, .echoAard, .echoAnsi, .colourNote,
             .hyperlink, .mapperCall, .chatCapture, .publish, .enableTrigger, .enableTimer, .enableGroup,
             .doAfter, .addTrigger, .addAlias, .setTriggerGroup, .setTriggerOption, .removeTrigger,
             .enableAlias, .reloadPlugin, .aardwolfTelnet, .accelerator, .http, .notify, .button,
             .sndCall, .playSound, .speak:
            recordEffect(function, arguments)
            return []
        case .call:
            guard let ref = exportedFunctions[Self.argString(arguments, 0)] else { return [] }
            return invokeFunction(ref, payload: Array(arguments.dropFirst()))
        case .getVar, .setVar, .deleteVar, .getPluginVar, .varList:
            return accessVariable(function, arguments)
        case .compileChunk:
            return compileChunk(arguments)
        case .moduleSource:
            return moduleSourceValue(arguments)
        case .jsonDecode, .jsonEncode:
            return jsonValue(function, arguments)
        case .info, .pluginID, .isConnected, .sqliteAllowed, .mapperMergeSQL, .monotonic,
             .fileExists, .makeDirectory, .readFile, .writeFile, .dialog, .clipboardGet,
             .clipboardSet, .databaseDir, .isPluginInstalled:
            return queryValue(function, arguments)
        default:
            // Miniwindow `window*` calls (see LuaRuntime+MiniWindow) and the
            // event-bus/RPC registration functions both land here.
            return miniWindowOrRegister(function, arguments)
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
        case .varList:
            // arg0 is the scope (empty → current); returns a {name=value} table.
            return variableList(arguments)
        default:
            break
        }
        return []
    }

    /// The event-bus / RPC registration & firing functions (no return value).
    nonisolated func registerOrRaise(_ function: HostFunction, _ arguments: [LuaValue]) {
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

    /// Mark a transient ref as owned (stored long-term), so it isn't freed at
    /// run-end. Returns the same ref. Pair with `luaL_unref` when done.
    nonisolated func claim(_ ref: Int32) -> Int32 {
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
    /// the stack for the caller to read and pop. (Internal so the typed
    /// expression readers in `LuaRuntime+Evaluation` can drive it.)
    func evaluate(_ expression: String) throws {
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
}

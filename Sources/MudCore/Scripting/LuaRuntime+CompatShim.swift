import CLua
import Foundation

/// The MUSHclient world-API compatibility shim (Phase 6, PLAN.md §7.3).
///
/// `loadCompatShim()` installs a set of global Lua functions
/// (`Send`, `Note`, `ColourNote`, `GetVariable`, `GetInfo`, …) that the
/// Aardwolf plugin corpus calls, implemented on top of the native
/// `proteles.*` API. This is the Tier-1 surface — the ~15 methods that
/// dominate the corpus (≈ColourNote 276, Note 230, Set/GetVariable 390,
/// GetInfo 165, CallPlugin 139, GetPluginID 80, EnableTrigger 74, …).
///
/// The XML plugin loader (next increment) installs this into each plugin's
/// environment and bundles the helper libraries (`json`, `serialize`,
/// `gmcphelper`, …) via a controlled module loader. Name-based
/// `EnableTrigger`/`Timer`/`Group` are stubs here — they become real once
/// the loader registers named triggers.
public extension LuaRuntime {
    /// Install the compatibility globals into the Lua state and register the
    /// standard helper libraries for `require`. Idempotent.
    func loadCompatShim() throws {
        _ = try run(Self.compatShimSource)
        _ = try run(Self.automationShimSource)
        registerModules(Self.standardHelpers)
        // The `wait` coroutine helper (and its `check` dependency) verbatim
        // from the Aardwolf package, so third-party plugins that `require
        // "wait"` work. They run on the programmatic-automation API above.
        registerModule("wait", source: SearchAndDestroyAssets.lua("wait") ?? "")
        registerModule("check", source: SearchAndDestroyAssets.lua("check") ?? "")
        // `async` is the Aardwolf HTTP/background-thread helper (LuaSocket +
        // SSL + llthreads). Proteles has no network helper, so we register an
        // inert stub: `require "async"` succeeds (a plugin's script loads and
        // its non-network commands work) and any `async.*(...)` is a no-op.
        registerModule("async", source: Self.asyncStubSource)
    }

    /// Inert `async` module: every field is a no-op function, so plugins that
    /// `require "async"` load and their network calls quietly do nothing.
    internal nonisolated static let asyncStubSource = """
    local function noop() return nil end
    async = setmetatable({}, { __index = function() return noop end })
    return async
    """

    /// Call a global Lua function by name (e.g. a plugin lifecycle callback
    /// like `OnPluginInstall`), returning the effects it recorded. A no-op
    /// when the global isn't a function. Errors surface as a red note rather
    /// than throwing, so a broken callback can't abort the host.
    @discardableResult
    func callGlobal(_ name: String, _ arguments: [LuaValue] = []) -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        defer { releaseTransientRefs() }
        clua_getglobal(state, name)
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            clua_pop(state, 1)
            return effects
        }
        for argument in arguments {
            luaPushValue(state, argument)
        }
        if lua_pcall(state, Int32(arguments.count), 0, 0) != 0 {
            effects.append(.note(
                text: "Lua callback error in \(name): \(Self.popMessage(state))",
                foreground: "red",
                background: nil
            ))
        }
        return effects
    }

    /// The shim source, applied on top of an existing `proteles` table.
    internal nonisolated static let compatShimSource = """
    -- MUSHclient world-API compatibility shim, mapped onto proteles.*.
    local proteles = proteles

    error_code = {
      eOK = 0,
      eWorldOpen = 30001,
      eWorldClosed = 30002,
      eNoNameSpecified = 30003,
      eCannotPlaySound = 30004,
      eTriggerNotFound = 30005,
      eTriggerAlreadyExists = 30006,
      eAliasNotFound = 30013,
      eTimerNotFound = 30017,
      eVariableNotFound = 30046,
      eOptionOutOfRange = 30024,
    }
    error_desc = error_desc or {}

    -- Output ----------------------------------------------------------------
    function Note(text)
      proteles.echo(text == nil and "" or tostring(text))
    end

    -- ColourNote(fore, back, text, fore2, back2, text2, ...): each (fore,
    -- back, text) triple becomes a styled segment on one line. Colours are
    -- coerced to strings ("" = default) and the whole triple list is handed
    -- to the host, which renders one styled run per segment.
    function ColourNote(...)
      local args = {...}
      local n = select("#", ...)
      local coerced = {}
      for i = 1, n do
        local v = args[i]
        coerced[i] = (v == nil) and "" or tostring(v)
      end
      proteles.colourNote(unpack(coerced, 1, n))
    end
    ColourTell = ColourNote
    function Tell(text)
      proteles.echo(text == nil and "" or tostring(text))
    end
    -- Render ANSI-SGR text in colour (often `AnsiNote(ColoursToANSI(text))`).
    function AnsiNote(text) proteles.echoAnsi(text == nil and "" or tostring(text)) end

    -- Sending ---------------------------------------------------------------
    function Send(text) proteles.send(tostring(text)); return error_code.eOK end
    function SendNoEcho(text) proteles.sendNoEcho(tostring(text)); return error_code.eOK end
    function Execute(text) proteles.execute(tostring(text)); return error_code.eOK end

    -- Variables -------------------------------------------------------------
    function GetVariable(name) return proteles.getVar(name) end
    function SetVariable(name, value)
      proteles.setVar(name, value == nil and "" or tostring(value))
      return error_code.eOK
    end
    function DeleteVariable(name) proteles.deleteVar(name); return error_code.eOK end
    function GetPluginVariable(id, name) return proteles.getPluginVar(id, name) end

    -- Introspection ---------------------------------------------------------
    function GetInfo(n) return proteles.info(n) end
    function GetPluginID() return proteles.pluginID() end
    function IsConnected() return proteles.isConnected() end
    -- GetPluginInfo(id, 20) = the plugin's directory; resolved for the
    -- current plugin via GetInfo(60). Other infotypes/plugins return nil.
    function GetPluginInfo(id, n)
      if id ~= GetPluginID() then return nil end
      if n == 20 then return proteles.info(60) end -- directory
      return proteles.info(n) -- 1 = name, 19 = version (others → nil)
    end

    -- GMCP ------------------------------------------------------------------
    function Send_GMCP_Packet(text) proteles.sendGMCP(tostring(text)); return error_code.eOK end

    -- print → Note (tab-joined, like MUSHclient's print override) -----------
    function print(...)
      local n = select("#", ...)
      local parts = {}
      for i = 1, n do parts[i] = tostring((select(i, ...))) end
      Note(table.concat(parts, "\\t"))
    end

    -- Inter-plugin ----------------------------------------------------------
    -- MUSHclient CallPlugin returns (status, results...); we report eOK and
    -- forward the callee's return values. Calls to the native GMCP mapper's
    -- well-known id are routed to it (find results arrive via OnPluginBroadcast
    -- 500/501, like the real mapper).
    function CallPlugin(id, fn, ...)
      if id == "b6eae87ccedd84f510b74714" then
        proteles.mapperCall(fn, ...); return error_code.eOK
      end
      return error_code.eOK, proteles.call(fn, ...)
    end
    function BroadcastPlugin(msg, text)
      proteles.broadcast(msg, text); return error_code.eOK
    end

    -- Automations: name-based enable/disable routes to the engine. A second
    -- arg that's false/nil/0 disables; anything else enables (MUSHclient
    -- passes a boolean, but some plugins pass 1/0).
    local function __on(flag) return not (flag == false or flag == nil or flag == 0) end
    function EnableTrigger(name, flag) proteles.enableTrigger(name, __on(flag)); return error_code.eOK end
    function EnableTimer(name, flag) proteles.enableTimer(name, __on(flag)); return error_code.eOK end
    function EnableGroup(name, flag) proteles.enableGroup(name, __on(flag)); return error_code.eOK end
    EnableTriggerGroup = EnableGroup
    EnableTimerGroup = EnableGroup

    -- String helpers MUSHclient exposes globally ---------------------------
    function Trim(s)
      if s == nil then return "" end
      return (tostring(s):gsub("^%s*(.-)%s*$", "%1"))
    end
    """

    /// The MUSHclient programmatic-automation surface (`AddTimer`/
    /// `AddTriggerEx`/`DeleteTrigger`/…), the `bit` library (absent in Lua
    /// 5.1), and the `module`/`package` shim — the dependencies the `wait`
    /// coroutine helper and many third-party plugins need. Registrations route
    /// to `proteles.*` effects, which ``ScriptEngine`` applies to its engines.
    internal nonisolated static let automationShimSource = #"""
    -- Bitwise ops (Lua 5.1 has none; MUSHclient exposes a global `bit`). -----
    bit = bit or {}
    local function _norm(x) return math.floor(tonumber(x) or 0) % 4294967296 end
    local function _binop(a, b, f)
      a, b = _norm(a), _norm(b)
      local r, p = 0, 1
      for _ = 0, 31 do
        local ab, bb = a % 2, b % 2
        if f(ab, bb) == 1 then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
      end
      return r
    end
    function bit.bor(a, b, ...)
      local r = _binop(a, b, function(x, y) return (x == 1 or y == 1) and 1 or 0 end)
      if select("#", ...) > 0 then return bit.bor(r, ...) end
      return r
    end
    function bit.band(a, b, ...)
      local r = _binop(a, b, function(x, y) return (x == 1 and y == 1) and 1 or 0 end)
      if select("#", ...) > 0 then return bit.band(r, ...) end
      return r
    end
    function bit.bxor(a, b, ...)
      local r = _binop(a, b, function(x, y) return (x ~= y) and 1 or 0 end)
      if select("#", ...) > 0 then return bit.bxor(r, ...) end
      return r
    end
    function bit.bnot(a) return (4294967295 - _norm(a)) end
    function bit.lshift(a, n) return _norm(_norm(a) * (2 ^ _norm(n))) end
    function bit.rshift(a, n) return math.floor(_norm(a) / (2 ^ _norm(n))) end

    -- module()/package shim (the sandbox removed `package`). Mirrors Lua 5.1's
    -- `module(name, package.seeall)` so helper libs like `wait` load. ---------
    package = package or { loaded = {} }
    package.loaded = package.loaded or {}
    function package.seeall(m)
      setmetatable(m, { __index = _G })
    end
    function module(name, ...)
      local m = package.loaded[name]
      if m == nil then m = {}; package.loaded[name] = m end
      m._NAME = name; m._M = m
      if name and not tostring(name):find("%.") then _G[name] = m end
      for _, modifier in ipairs({ ... }) do modifier(m) end
      setfenv(2, m)
    end

    -- MUSHclient flag constants (mushclient/flags.h). trigger_flag values MUST
    -- match the host's decoder (ScriptEngine.TriggerFlag). -------------------
    timer_flag = {
      Enabled = 1, AtTime = 2, OneShot = 4, Active = 32, Replace = 1024,
      TimerSpeedWalk = 8, TimerNote = 16, Temporary = 16384,
      ActiveWhenClosed = 256,
    }
    trigger_flag = {
      Enabled = 1, OmitFromLog = 2, OmitFromOutput = 4, KeepEvaluating = 8,
      IgnoreCase = 16, RegularExpression = 32, ExpandVariables = 512,
      Replace = 1024, LowercaseWildcard = 2048, Temporary = 16384, OneShot = 32768,
    }
    -- AddAlias flag bits (mushclient/flags.h — distinct from trigger bits).
    alias_flag = {
      Enabled = 1, IgnoreCase = 32, OmitFromLogFile = 64,
      RegularExpression = 128, OmitFromOutput = 256, Temporary = 16384,
      OneShot = 32768,
    }
    custom_colour = { NoChange = -1 }

    local _unique = 0
    function GetUniqueNumber() _unique = _unique + 1; return _unique end
    -- Plugins gate the `wait` helper on these being enabled.
    function GetOption(name)
      if name == "enable_timers" or name == "enable_triggers" then return 1 end
      return 0
    end
    -- String-valued world/plugin options. We don't persist these yet; return a
    -- blank string (the MUSHclient default for an unset alpha option) and accept
    -- writes as eOK so plugins that read/write them (e.g. autobypass on reload)
    -- don't error.
    function GetAlphaOption(name) return "" end
    function SetAlphaOption(name, value) return error_code.eOK end
    -- GetEchoInput: whether typed input is locally echoed. dinv reads it to
    -- restore the prior state around its prompt reads; default on (1).
    function GetEchoInput() return 1 end
    -- Clipboard: not yet wired to the native pasteboard (MudCore is
    -- platform-agnostic). Reads return empty; writes are accepted as eOK so
    -- copy/paste features (e.g. dinv priority copy) don't error.
    function GetClipboard() return "" end
    function SetClipboard(text) return error_code.eOK end
    -- Convert a plain (literal/wildcard) match to a regex, like MUSHclient's
    -- MakeRegularExpression — escape regex metacharacters so wait.match treats
    -- its text literally.
    function MakeRegularExpression(text)
      return "^" .. tostring(text):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]", "\\%0") .. "$"
    end

    -- Programmatic timers/triggers → host effects. AddTimer becomes a one-shot
    -- deferred call to its script (the only shape `wait` uses); the response/
    -- send-to and DeleteTimer are no-ops (one-shots expire). AddTriggerEx
    -- registers a (one-shot) trigger whose script fires on match. -----------
    function AddTimer(name, hour, minute, second, response, flags, script)
      local seconds = (tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60
        + (tonumber(second) or 0)
      if script and script ~= "" then
        proteles.doAfter(seconds, script .. "(" .. string.format("%q", tostring(name)) .. ")", true)
      end
      return error_code.eOK
    end
    function AddTriggerEx(name, match, response, flags, colour, wildcard, sound, script, sendto, seq)
      proteles.addTrigger(tostring(name), tostring(match), tonumber(flags) or 0, script or "")
      return error_code.eOK
    end
    function AddTrigger(name, match, response, flags, colour, wildcard, sound, script)
      proteles.addTrigger(tostring(name), tostring(match), tonumber(flags) or 0, script or "")
      return error_code.eOK
    end
    function DeleteTrigger(name) proteles.removeTrigger(tostring(name)); return error_code.eOK end
    -- AddAlias/EnableAlias: register/toggle a runtime alias on the host's alias
    -- engine (owner-scoped, like AddTriggerEx). `script` is the handler name.
    function AddAlias(name, match, response, flags, script)
      proteles.addAlias(tostring(name), tostring(match), tonumber(flags) or 0, script or "")
      return error_code.eOK
    end
    function EnableAlias(name, flag)
      proteles.enableAlias(tostring(name), not (flag == false or flag == nil or flag == 0))
      return error_code.eOK
    end
    function DeleteTimer(name) return error_code.eOK end
    function SetTimerOption(name, option, value) return error_code.eOK end
    function SetTriggerOption(name, option, value) return error_code.eOK end
    function DeleteTemporaryTriggers() return 0 end
    function DeleteTemporaryTimers() return 0 end
    """#
}

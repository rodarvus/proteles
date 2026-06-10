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
        _ = try run(Self.utilsShimSource)
        _ = try run(Self.ioShimSource)
        registerModules(Self.standardHelpers)
        // Nick Gammon's `wait` coroutine helper (and its `check` dependency),
        // bundled (see MUSHHelperAssets), so third-party plugins that
        // `require "wait"` work. They run on the programmatic-automation API.
        registerModule("wait", source: MUSHHelperAssets.lua("wait") ?? "")
        registerModule("check", source: MUSHHelperAssets.lua("check") ?? "")
        // `string_split` (another Nick Gammon `lua/` helper) defines the global
        // `string.split`; third-party plugins `require "string_split"` (e.g.
        // Hadar's spellup / double-predictor). It lives in MUSHclient's shared
        // `lua/` dir, which the world importer doesn't copy — so provide it here.
        registerModule("string_split", source: MUSHHelperAssets.lua("string_split") ?? "")
        // `async` is the Aardwolf HTTP/background-thread helper (LuaSocket +
        // SSL + llthreads upstream). Proteles implements it natively over
        // URLSession: `doAsyncRemoteRequest`/`HEAD`/`GETFILE` route to
        // `proteles.__http`, the host performs the request and fires the
        // callback (see `LuaRuntime+HTTP`). docs/plans/ASYNC_HTTP_PLAN.md.
        registerModule("async", source: Self.asyncModuleSource)
        // `checkplugin` + `aard_requirements` are the Aardwolf package's
        // dependency-nag framework: a plugin `dofile`s `aard_requirements.lua`
        // (which `require`s `checkplugin` and calls `do_plugin_check_now`) to
        // warn if a *companion MUSHclient plugin* isn't installed. Proteles has
        // no MUSHclient plugin registry/PPI, so that check is meaningless — we
        // register no-op stubs so dependency-gated plugins (e.g. mudbin's
        // `OnPluginListChanged`) load clean instead of erroring on a missing file.
        registerModule("checkplugin", source: Self.checkpluginStubSource)
        registerModule("aard_requirements", source: "-- Proteles no-op: see checkplugin stub.")
    }

    /// Native `async` module (clean-room) over `proteles.__http`: the reference's
    /// `doAsyncRemoteRequest`/`HEAD`/`GETFILE` with the same signatures, so
    /// plugins run unmodified. A string callback is `loadstring`d (as upstream).
    /// The host fires it with `(retval, page, status, headers, full_status,
    /// url, body)`.
    internal nonisolated static let asyncModuleSource = """
    async = {}
    local function as_func(cb)
      if type(cb) == "string" then return loadstring(cb) end
      return cb
    end
    local function protocol_for(url, p)
      if p and p ~= "" then return p end
      return tostring(url):lower():find("^https:") and "HTTPS" or "HTTP"
    end
    function async.doAsyncRemoteRequest(url, callback, protocol, timeout, on_timeout, body)
      proteles.__http("request", tostring(url), protocol_for(url, protocol),
        tonumber(timeout) or 30, body, as_func(callback), as_func(on_timeout))
    end
    function async.HEAD(url, callback, protocol, timeout, on_timeout)
      proteles.__http("head", tostring(url), protocol_for(url, protocol),
        tonumber(timeout) or 30, nil, as_func(callback), as_func(on_timeout))
    end
    function async.GETFILE(url, callback, protocol, file_name, timeout, on_timeout)
      proteles.__http("getfile", tostring(url), protocol_for(url, protocol),
        tonumber(timeout) or 30, file_name, as_func(callback), as_func(on_timeout))
    end
    return async
    """

    /// No-op `checkplugin`: defines the same globals the real one does
    /// (`do_plugin_check_now`/`checkplugin`/`load_ppi`) so a plugin's dependency
    /// check is a harmless no-op rather than a "you must install X" nag for a
    /// MUSHclient plugin that doesn't exist (and isn't needed) in Proteles.
    internal nonisolated static let checkpluginStubSource = """
    function do_plugin_check_now() end
    function checkplugin() end
    function load_ppi() return nil end
    return { do_plugin_check_now = do_plugin_check_now, checkplugin = checkplugin, load_ppi = load_ppi }
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
      eVariableNotFound = 30019,
      eOptionOutOfRange = 30024,
      eBadParameter = 30046,
    }
    error_desc = error_desc or {}

    -- Output ----------------------------------------------------------------
    -- Tell/ColourTell APPEND coloured segments to `__pending`; Note/ColourNote/
    -- AnsiNote/print FLUSH them as one line — a ColourTell row keeps its colours.
    local __pending = {}
    -- Flush `__pending` + `extra` ({fg,bg,text} array) as one colourNote line.
    local function __flush(extra)
      local segs = __pending; __pending = {}
      if extra then for i = 1, #extra do segs[#segs + 1] = extra[i] end end
      local flat, k = {}, 0
      for i = 1, #segs do flat[k+1], flat[k+2], flat[k+3] = segs[i][1], segs[i][2], segs[i][3]; k = k + 3 end
      proteles.colourNote(unpack(flat, 1, k))
    end
    function Tell(text) __pending[#__pending + 1] = { "", "", text == nil and "" or tostring(text) } end
    function ColourTell(...) -- buffer each triple as a coloured cell
      local a, n = {...}, select("#", ...)
      for b = 1, n, 3 do
        __pending[#__pending + 1] = {
          a[b]     == nil and "" or tostring(a[b]),
          a[b + 1] == nil and "" or tostring(a[b + 1]),
          a[b + 2] == nil and "" or tostring(a[b + 2]),
        }
      end
    end
    function Note(text)
      text = text == nil and "" or tostring(text)
      if #__pending == 0 then proteles.echo(text)
      else __flush({ { "", "", text } }) end
    end
    -- ColourNote(fore, back, text, ...): each triple → a styled cell, after pending.
    function ColourNote(...)
      local a, n = {...}, select("#", ...)
      local extra = {}
      for b = 1, n, 3 do
        extra[#extra + 1] = {
          a[b]     == nil and "" or tostring(a[b]),
          a[b + 1] == nil and "" or tostring(a[b + 1]),
          a[b + 2] == nil and "" or tostring(a[b + 2]),
        }
      end
      __flush(extra)
    end
    -- Render ANSI-SGR text in colour. A pending tag prefix is flattened to its
    -- text (a coloured prefix + an ANSI body can't share one effect).
    function AnsiNote(text)
      local prefix = ""
      for i = 1, #__pending do prefix = prefix .. __pending[i][3] end
      __pending = {}
      proteles.echoAnsi(prefix .. (text == nil and "" or tostring(text)))
    end
    -- GetNormalColour(n)/GetBoldColour(n): the world's ANSI colour n as a BGR int,
    -- matching MUSHColour (Swift) so a trigger's styles[i].textcolour compares.
    -- ONE-BASED like MUSHclient (methods_colours.cpp: bounds 1..8, [n-1] lookup,
    -- out of range returns 0) — 7 is CYAN, 8 is white. A 0-based table here
    -- broke every plugin colour guard: rsocials compares styles[1].textcolour
    -- to GetNormalColour(7), got white instead of cyan, and never forwarded.
    local __nc = { 0, 128, 32768, 32896, 8388608, 8388736, 8421376, 12632256 }
    local __bc = { 8421504, 255, 65280, 65535, 16711680, 16711935, 16776960, 16777215 }
    function GetNormalColour(w) return __nc[tonumber(w) or 0] or 0 end
    function GetBoldColour(w) return __bc[tonumber(w) or 0] or 0 end
    -- Hyperlink(action, text, hint): clickable text → the native primitive
    -- (action: URL → opens browser, else sent as a command). A pending prefix is
    -- flushed first; inline composition with Tell/Note isn't supported.
    function Hyperlink(action, text, hint)
      if #__pending > 0 then __flush(nil) end
      proteles.hyperlink(tostring(text or ""), tostring(action or ""), hint and tostring(hint) or nil)
      return error_code.eOK
    end
    -- MakeHyperlink returns embedded style codes in MUSHclient; we have no such
    -- inline representation, so it degrades to the plain text (visible, not
    -- clickable). Use Hyperlink for a clickable link.
    function MakeHyperlink(action, text) return tostring(text or "") end

    -- Sending ---------------------------------------------------------------
    function Send(text) proteles.send(tostring(text)); return error_code.eOK end
    function SendNoEcho(text) proteles.sendNoEcho(tostring(text)); return error_code.eOK end
    -- Notify(title[, body]): raise a native macOS notification (Proteles
    -- extension; gated by the user's master notifications enable). The
    -- extensibility hook so any trigger/alias/plugin can alert the user — and
    -- the regex escape-hatch for keyword alerts (a regex trigger calls Notify).
    function Notify(title, body)
      proteles.notify(tostring(title or ""), tostring(body or ""))
      return error_code.eOK
    end
    -- Command-button bar (#15): create/update/toggle buttons from scripts/plugins
    -- (a Proteles extension — Mudlet can only toggle pre-made buttons). The app
    -- applies the change to the live bar + persists it per-world.
    Button = {
      add = function(group, label, command)
        proteles.button("add", tostring(group or "Buttons"), tostring(label or ""), tostring(command or ""))
      end,
      toggle = function(group, label, onCmd, offCmd)
        proteles.button("toggle", tostring(group or "Buttons"), tostring(label or ""),
                        tostring(onCmd or ""), tostring(offCmd or ""))
      end,
      state = function(label, on) proteles.button("state", tostring(label or ""), on and "1" or "0") end,
      remove = function(label) proteles.button("remove", tostring(label or "")) end,
    }
    -- Sounds (#10): PlaySound(buffer, file, loop, volume_dB, pan) plays a
    -- one-shot cue through the app's player. Buffer management and looping
    -- don't apply (each cue is fire-and-forget); volume is MUSHclient dB
    -- (0 = full, out-of-range coerces to full — S&D passes 100), pan is
    -- −100…100. A relative filename resolves against the user's Sounds dir
    -- (GetInfo(74)); the host converts units. Sound(file) is the simple form.
    function PlaySound(buffer, file, loop, volume, pan)
      file = tostring(file or "")
      if file == "" then return error_code.eBadParameter end
      proteles.playSound(file, tonumber(volume) or 0, tonumber(pan) or 0)
      return error_code.eOK
    end
    function Sound(file) return PlaySound(0, file, false, 0, 0) end
    -- One-shot playback: nothing is ever "still playing" to stop or query.
    function StopSound(buffer) return error_code.eOK end
    function GetSoundStatus(buffer) return -3 end -- not playing

    -- SendSpecial(Message, Echo, Queue, Log, History): MUSHclient's send with
    -- options. We honour Echo (true → echo like Send; false/nil → no echo);
    -- Queue/Log/History don't apply and are ignored. The common one-arg call
    -- (e.g. Double Predictor's `SendSpecial(text)`) behaves like SendNoEcho.
    function SendSpecial(message, echo, queue, log, history)
      message = tostring(message)
      if echo then proteles.send(message) else proteles.sendNoEcho(message) end
      return error_code.eOK
    end
    -- MUSHclient's Execute runs world input. A backslash-prefixed run (the
    -- MUSHclient script-prefix convention) is executed as Lua in the caller's
    -- env rather than sent (dinv's self-reload Execute("\\\\\\DoAfterSpecial(…)")).
    function Execute(text)
      text = tostring(text)
      local stripped = text:gsub("^\\\\+", "")
      if stripped ~= text then
        local chunk = loadstring(stripped)
        if chunk then chunk() end
        return error_code.eOK
      end
      proteles.execute(text); return error_code.eOK
    end

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
    -- GetPluginName() = the current plugin's name; GetPluginName(id) for any
    -- other plugin is unknown to us (we only host the current one) → "".
    function GetPluginName(id)
      if id == nil or id == GetPluginID() then return proteles.info(1) or "" end
      return ""
    end
    -- Plugin enable/disable + presence. We host one plugin per environment and
    -- can't toggle another plugin from Lua, so these are benign no-ops that
    -- report success: a plugin that disables itself on install (then `return`s)
    -- simply proceeds, and callers wrapping the call in `check()` see eOK.
    function EnablePlugin(id, flag) return error_code.eOK end
    function DisablePlugin(id) return error_code.eOK end
    -- True for the caller itself, any LOADED shim plugin, and the natively-
    -- bridged ids (GMCP handler, chat capture, mapper, S&D when attached) —
    -- plugins gate whole features on these (campaign mode checks for S&D).
    function IsPluginInstalled(id)
      if id == nil or id == GetPluginID() then return true end
      return proteles.isPluginInstalled(tostring(id)) == true
    end
    -- check(code): MUSHclient's return-code guard (lua/check.lua) — raise a Lua
    -- error if an API call didn't return eOK, else pass the code through. Our
    -- API functions return eOK on success, so check() is a no-op on the happy
    -- path (plugins wrap calls like `check(AddTimer(...))`).
    function check(code)
      if code ~= nil and code ~= error_code.eOK then
        error("MUSHclient API call failed with code " .. tostring(code), 2)
      end
      return code
    end
    -- SaveState(): MUSHclient persists plugin state on demand. We write variables
    -- through automatically, so this just runs the plugin's OnPluginSaveState (if
    -- any) — where it sets the variables to persist — and reports success.
    function SaveState()
      if type(OnPluginSaveState) == "function" then pcall(OnPluginSaveState) end
      return error_code.eOK
    end
    -- Keyboard accelerators (MUSHclient Accelerator/AcceleratorTo) bridge to the
    -- native MacroEngine: the key chord is parsed and registered so the keypress
    -- fires `send` (as a command, or as Lua when sendto == sendto.script). An
    -- unrecognised key is ignored. Returns eOK like the real API.
    function Accelerator(key, send)
      proteles.accelerator(tostring(key or ""), tostring(send or ""), 0)
      return error_code.eOK
    end
    function AcceleratorTo(key, send, sendto)
      proteles.accelerator(tostring(key or ""), tostring(send or ""), tonumber(sendto) or 0)
      return error_code.eOK
    end

    -- MUSHclient also exposes the API as fields on a global `world` object
    -- (`world.Note(...)` ≡ `Note(...)`); proxy field access to the matching
    -- global (resolved at call time, so later-defined functions are reachable).
    world = setmetatable({}, { __index = function(_, key) return _G[key] end })

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
    -- CallPlugin returns (status, results...); we report eOK + forward returns.
    -- The native GMCP mapper's id routes to it (results via OnPluginBroadcast
    -- 500/501). __toLuaLiteral serializes a gmcp subtree to a Lua-literal string.
    local function __toLuaLiteral(v)
      local t = type(v)
      if t == "table" then
        local parts = {}
        for k, val in pairs(v) do
          local key = type(k) == "number" and ("[" .. k .. "]")
            or ("[" .. string.format("%q", tostring(k)) .. "]")
          parts[#parts + 1] = key .. "=" .. __toLuaLiteral(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      elseif t == "number" or t == "boolean" then
        return tostring(v)
      else
        return string.format("%q", tostring(v))
      end
    end
    function CallPlugin(id, fn, ...)
      if id == "b6eae87ccedd84f510b74714" then
        proteles.mapperCall(fn, ...); return error_code.eOK
      end
      -- Aardwolf GMCP handler: gmcpval/gmcpdata_as_string(path) return a
      -- Lua-literal string of the GMCP subtree (the reference handler does
      -- `serialize.save_simple(gmcpdata_at_level(path) or "")`). Bridge to our
      -- live gmcp() accessor so plugins that fetch GMCP via CallPlugin work.
      if id == "3e7dedbe37e44942dd46d264" and (fn == "gmcpval" or fn == "gmcpdata_as_string") then
        require "gmcphelper" -- ensure gmcp() is defined
        local args = {...}
        return error_code.eOK, __toLuaLiteral(gmcp(args[1]))
      end
      -- Search & Destroy runs natively on its own host runtime. Its read
      -- accessors answer SYNCHRONOUSLY from `__snd_state` — the snapshot the
      -- host re-mirrors here whenever it changes — because `proteles.sndCall`
      -- is an effect applied only after this Lua call returns, so it can
      -- never carry a return value back (a campaign-driving plugin read nil
      -- here and wrongly concluded "no active campaign" while S&D was
      -- mid-hunt). An accessor S&D doesn't define has no mirrored key and
      -- returns no result (the callers' degrade path). Everything else
      -- forwards as a fire-and-forget call (do_cp_check etc.).
      if id == "30000000537461726C696E67" then
        if fn == "target_as_json" or fn == "targets_as_json" or fn == "goto_list_count" then
          local state = __snd_state
          return error_code.eOK, state and state[fn]
        end
        proteles.sndCall(fn, ...); return error_code.eOK
      end
      -- Aardwolf Chat Capture plugin: storeFromOutside(text, tab, foreground)
      -- adds a line under a tab. Bridge it to native chat (rsocial, hadar
      -- spellup, …) so captured lines land in the Channels panel.
      if id == "b555825a4a5700c35fa80780" and fn == "storeFromOutside" then
        local args = {...}
        proteles.chatCapture(args[1] or "", args[2] or "")
        return error_code.eOK
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
    /// The full compat-shim Lua source = the core API here + the timers /
    /// plugin-control extras in `LuaRuntime+CompatShimTimers.swift`. Split across
    /// two files to stay within the file-length budget; concatenated verbatim
    /// (with a newline) into one Lua chunk by ``loadCompatShim()``.
    internal nonisolated static var automationShimSource: String {
        shimSourceCore + "\n" + shimSourceTimersAndPlugins
    }

    private nonisolated static let shimSourceCore = #"""
    -- Name registries so IsTrigger/IsTimer/IsAlias can answer existence
    -- (MUSHclient object names are world-unique). Add*/Delete* keep these in
    -- sync; dinv's de-init whacks objects by name and treats "not found" as a
    -- successful no-op, so an accurate registry keeps it from erroring on quit.
    local __triggerNames, __timerNames, __aliasNames = {}, {}, {}
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
    -- MUSHclient custom-colour selectors (NoChange + Custom1..Custom16). We
    -- don't apply per-trigger colours, but plugins index these (e.g. as the
    -- AddTriggerEx colour arg), so they must be present + non-nil.
    custom_colour = { NoChange = -1 }
    for i = 1, 16 do custom_colour["Custom" .. i] = i - 1 end
    -- MUSHclient send-target constants (mushclient/OtherTypes.h): sendto.script
    -- (12) / sendto.execute (10) etc., used as the DoAfterSpecial/AddTriggerEx
    -- target. Indexing a nil here aborts the calling chunk.
    sendto = {
      world = 0, command = 1, output = 2, status = 3, notepad = 4,
      appendtonotepad = 5, logfile = 6, replacenotepad = 7, commandqueue = 8,
      variable = 9, execute = 10, speedwalk = 11, script = 12, immediate = 13,
      scriptafteromit = 14,
    }

    -- MUSHclient version (plugins gate features on `tonumber(Version())`);
    -- report a recent release so version checks pass.
    function Version() return "5.07" end
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
    -- GetEchoInput/SetEchoInput: whether typed input is locally echoed. We
    -- don't suppress local echo (the native input field owns that), but dinv's
    -- prompt-read path saves/sets/restores it around a read, so the round-trip
    -- must be consistent: track a shim-local flag (default on) so a saved value
    -- restores faithfully and SetEchoInput(false) doesn't break the caller.
    local __echoInput = 1
    function GetEchoInput() return __echoInput end
    function SetEchoInput(flag)
      __echoInput = (flag == false or flag == nil or flag == 0) and 0 or 1
      return error_code.eOK
    end
    -- Clipboard: routes to the app's injected pasteboard provider (NSPasteboard
    -- on macOS). With no provider (headless / tests) reads return "" and writes
    -- are accepted, so copy/paste features (e.g. dinv priority copy) don't error.
    function GetClipboard() return proteles.clipboardGet() or "" end
    function SetClipboard(text) proteles.clipboardSet(tostring(text or "")); return error_code.eOK end
    -- Convert a plain (literal/wildcard) match to a regex, like MUSHclient's
    -- MakeRegularExpression — escape regex metacharacters so wait.match treats
    -- its text literally.
    function MakeRegularExpression(text)
      return "^" .. tostring(text):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]", "\\%0") .. "$"
    end
    """#
}

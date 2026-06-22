import CLua
import Foundation

/// The MUSHclient world-API compatibility shim (Phase 6, ARCHITECTURE.md §7.3).
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
        _ = try run(Self.miniWindowShimSource)
        _ = try run(Self.databaseShimSource)
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
        // `rex` (lrexlib/PCRE) over Proteles' ICU regex (PatternMatcher), which
        // already bridges PCRE named captures. See LuaRuntime+CompatRegex.
        registerModule("rex", source: Self.rexModuleSource)
    }

    // `asyncModuleSource` (the clean-room `async` HTTP module) lives in
    // LuaRuntime+AsyncModule.swift to keep this file under the line budget.

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
        beginMiniWindowPass()
        defer { releaseTransientRefs() }
        clua_getglobal(state, name)
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            clua_pop(state, 1)
            return effects
        }
        for argument in arguments {
            luaPushValue(state, argument)
        }
        if protectedCall(nargs: Int32(arguments.count), nresults: 0) != 0 {
            let message = "Lua callback error in \(name): \(Self.popMessage(state))"
            effects.append(.note(text: message, foreground: "red", background: nil))
            effects.append(contentsOf: sourceContextEffects(forError: message))
        }
        flushMiniWindows()
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
      eUnknownOption = 30025,
      ePluginFileNotFound = 30030,
      eNoSuchPlugin = 30034,
      eNoSuchRoutine = 30036,
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
    -- Append one coloured cell, honouring embedded newlines: a newline in the
    -- text COMPLETES the current line (flushes `__pending` as one colourNote) and
    -- starts a fresh one — matching MUSHclient, where a newline in Tell/ColourTell
    -- text breaks the line. Without this, a plugin that builds a table with
    -- ColourTell and ends on a trailing-newline cell (no terminating Note — a very
    -- common idiom, e.g. a list/messages table) accumulated the WHOLE table in
    -- `__pending` and never emitted it, so its output vanished (it only surfaced
    -- later, prepended to the next ColourNote that happened to flush).
    local function __appendCell(fore, back, text)
      fore = fore == nil and "" or tostring(fore)
      back = back == nil and "" or tostring(back)
      text = text == nil and "" or tostring(text)
      local start = 1
      while true do
        local nl = text:find("\\n", start, true)
        if not nl then
          local rest = text:sub(start)
          if rest ~= "" then __pending[#__pending + 1] = { fore, back, rest } end
          return
        end
        local chunk = text:sub(start, nl - 1)
        if chunk ~= "" then __pending[#__pending + 1] = { fore, back, chunk } end
        __flush() -- emit everything up to (not including) the newline as one line
        start = nl + 1
      end
    end
    function Tell(text) __appendCell("", "", text) end
    function ColourTell(...) -- buffer each triple as a coloured cell (newline-aware)
      local a, n = {...}, select("#", ...)
      for b = 1, n, 3 do __appendCell(a[b], a[b + 1], a[b + 2]) end
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
    -- ColourNameToRGB(name)/RGBColourToName(int): MUSHclient's 148 named colours
    -- <-> COLORREF (red low byte). Delegated to Swift (MUSHColour) so the table
    -- lives in one place. ColourNameToRGB also parses a "#rrggbb" literal and
    -- returns -1 for an unknown name; RGBColourToName returns "#RRGGBB" when no
    -- name matches the int.
    function ColourNameToRGB(name) return proteles.colourNameToRGB(name == nil and "" or tostring(name)) end
    function RGBColourToName(colour) return proteles.rgbColourToName(tonumber(colour) or 0) end
    -- AdjustColour(colour, method): invert/lighten/darken/(de)saturate a COLORREF
    -- (method 1..5; see MUSHColour). CreateGUID()/GetUniqueID(): id strings (an
    -- uppercase dashed GUID; 24 lowercase hex chars).
    function AdjustColour(colour, method)
      return proteles.adjustColour(tonumber(colour) or 0, tonumber(method) or 0)
    end
    function CreateGUID() return proteles.createGUID() end
    function GetUniqueID() return proteles.uniqueID() end
    -- Output-buffer introspection. Line numbers are 1-indexed (1 = oldest line
    -- still in the buffer); GetLineCount is the running total since connect,
    -- GetLinesInBufferCount the current buffer size. GetLineInfo(n) (or
    -- GetLineInfo(n, 0)) returns the all-fields table; a specific infotype
    -- returns that scalar (nil if the line is out of range / infotype unknown).
    function GetLineCount() return proteles.lineCount() end
    function GetLinesInBufferCount() return proteles.linesInBuffer() end
    function GetRecentLines(count) return proteles.recentLines(tonumber(count) or 0) end
    function GetStyleInfo(line, style, infotype)
      return proteles.styleInfo(tonumber(line) or 0, tonumber(style) or 0, tonumber(infotype) or 0)
    end
    function GetLineInfo(line, infotype)
      line = tonumber(line) or 0
      if infotype ~= nil and infotype ~= 0 then
        return proteles.lineInfo(line, tonumber(infotype) or 0)
      end
      if proteles.lineInfo(line, 1) == nil then return nil end -- out-of-range line
      return {
        text = proteles.lineInfo(line, 1), length = proteles.lineInfo(line, 2),
        newline = proteles.lineInfo(line, 3), note = proteles.lineInfo(line, 4),
        user = proteles.lineInfo(line, 5), log = proteles.lineInfo(line, 6),
        bookmark = proteles.lineInfo(line, 7), hr = proteles.lineInfo(line, 8),
        time = proteles.lineInfo(line, 9), line = proteles.lineInfo(line, 10),
        styles = proteles.lineInfo(line, 11), ticks = proteles.lineInfo(line, 12),
        elapsed = proteles.lineInfo(line, 13),
      }
    end
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
    -- Simulate(text): inject `text` as if it arrived from the MUD (re-fed
    -- through the inbound pipeline, so triggers see it and it displays) — the
    -- generic-shim twin of the S&D binding (the most-used world fn missing from
    -- the shim per docs/MUSHCLIENT_LUA_GAP.md).
    function Simulate(text)
      proteles.simulate(text == nil and "" or tostring(text))
      return error_code.eOK
    end
    -- ANSI(code, ...): build an ANSI escape from numeric codes — pure, exact to
    -- MUSHclient (ESC "[" .. codes joined by ";" .. "m"; no args -> ESC "[m").
    function ANSI(...)
      local parts, n = {}, select("#", ...)
      for i = 1, n do parts[i] = string.format("%i", math.floor(tonumber((select(i, ...))) or 0)) end
      return "\\27[" .. table.concat(parts, ";") .. "m"
    end

    -- Variables -------------------------------------------------------------
    function GetVariable(name) return proteles.getVar(name) end
    function SetVariable(name, value)
      proteles.setVar(name, value == nil and "" or tostring(value))
      return error_code.eOK
    end
    function DeleteVariable(name) proteles.deleteVar(name); return error_code.eOK end
    function GetPluginVariable(id, name) return proteles.getPluginVar(id, name) end
    -- Both always return a table (empty when the scope has no variables),
    -- matching MUSHclient — callers iterate the result without a nil guard.
    function GetVariableList() return proteles.varList() end
    function GetPluginVariableList(id) return proteles.varList(id) end

    -- Introspection ---------------------------------------------------------
    function GetInfo(n) return proteles.info(n) end
    function GetPluginID() return proteles.pluginID() end
    function IsConnected() return proteles.isConnected() end
    -- WorldName(): the current world's name (GetInfo(2)); defaults to the only
    -- world Proteles targets when unset.
    function WorldName() return proteles.info(2) or "Aardwolf" end
    -- GetPluginInfo(id, 20) = the plugin's directory; resolved for the
    -- current plugin via GetInfo(60). Other infotypes/plugins return nil.
    function GetPluginInfo(id, n)
      if id ~= GetPluginID() then return nil end
      if n == 20 then return proteles.info(60) end -- directory
      -- 6 = plugin source-file path. We don't track the .xml filename, but many
      -- plugins (fixpath.lua, self-updaters) only string.match it down to the
      -- directory — so returning the plugin dir keeps them from crashing on a nil.
      if n == 6 then return proteles.info(60) end
      if n == 17 then return true end -- enabled: the current plugin is loaded + running
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
    -- GetPluginList(): ids of the loaded shim plugins + the natively-bridged
    -- ids + the caller. Always non-empty (the caller is present), so the common
    -- `for _, id in ipairs(GetPluginList())` can't hit ipairs(nil).
    function GetPluginList() return proteles.pluginList() end
    -- PluginSupports(id, routine): eOK if plugin `id` defines a global function
    -- `routine`, else eNoSuchRoutine (also for bridged/native ids, whose
    -- routines aren't enumerable). Used to discover companion plugins.
    function PluginSupports(id, routine)
      if proteles.pluginSupports(tostring(id or ""), tostring(routine or "")) == true then
        return error_code.eOK
      end
      return error_code.eNoSuchRoutine
    end
    -- UnloadPlugin(id): drop a loaded shim plugin (idempotent for an unknown/
    -- native id). A plugin can't unload itself mid-script (eBadParameter), as in
    -- MUSHclient. Returns eOK; the host removes its env + owned automations.
    function UnloadPlugin(id)
      local key = tostring(id or "")
      if key == GetPluginID() then return error_code.eBadParameter end
      proteles.unloadPlugin(key)
      return error_code.eOK
    end
    -- LoadPlugin(file): MUSHclient loads a plugin from a path at runtime. Proteles
    -- installs plugins through the Plugin Library (not arbitrary runtime file
    -- loads), so this is a logged no-op returning eOK — a dependency-checker that
    -- calls it won't error; the plugin itself is added via the Library.
    function LoadPlugin(file)
      proteles.trace("LoadPlugin (use the Plugin Library to add plugins): " .. tostring(file or ""))
      return error_code.eOK
    end
    -- Connect(): open the connection if closed (re-using the last endpoint);
    -- eWorldOpen when already connected, matching MUSHclient's guard idiom
    -- `if not IsConnected() then Connect() end`.
    function Connect()
      if proteles.isConnected() == true then return error_code.eWorldOpen end
      proteles.connect()
      return error_code.eOK
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
    -- EnableAliasGroup: the host enableGroup now toggles the named group across
    -- triggers/timers/aliases, so the alias-group variant routes here too.
    EnableAliasGroup = EnableGroup

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
}

import Foundation

/// The curated MUSHclient API S&D runs against (split out of the actor to
/// keep its body within the type-length budget). Globals over `proteles.*`:
/// output/comms/vars map to real primitives; the miniwindow + a few options
/// are stubs (replaced by the native panel).
extension SearchAndDestroyHost {
    /// The MUSHclient API S&D uses, defined as globals over `proteles.*`.
    /// Output/comms/vars/timers map to real primitives; the miniwindow + a few
    /// options are stubs (replaced by native UI / wired in later stages).
    static let bindings = """
    -- Lua 5.1 module system (the sandbox removes it; some vendored helper libs
    -- like `wait`/`check` declare themselves with `module(..., package.seeall)`).
    package = package or { loaded = {}, path = "", cpath = "" }
    package.seeall = function(m) setmetatable(m, { __index = _G }) end
    function module(name, ...)
      local m = package.loaded[name]
      if m == nil then m = {}; package.loaded[name] = m end
      m._NAME = name; m._M = m
      if name and not name:find("%.") then _G[name] = m end
      for _, modifier in ipairs({...}) do modifier(m) end
      setfenv(2, m)  -- the calling chunk's environment becomes the module
    end

    -- Capture the Lua built-ins our output primitives call into upvalues. S&D's
    -- `search_rooms` assigns `select = string.format(...)` WITHOUT `local`, so
    -- the first quick-where/search that renders a result list clobbers the
    -- global `select` with a string — and our print/ColourTell shims call
    -- `select()`/`unpack()`. On MUSHclient that clobber is harmless (its `print`
    -- is a C primitive and core never CALLS select()); here it would silently
    -- break ALL subsequent output (qw/go/nx render nothing). Bind the originals
    -- now so the shims are immune (parity with the os.clock/math.random fixes).
    local select, unpack = select, unpack

    -- Output + comms ---------------------------------------------------------
    function Send(s) proteles.send(s); return 0 end
    function SendNoEcho(s) proteles.sendNoEcho(s); return 0 end
    function Execute(s) proteles.execute(s); return 0 end
    -- Output line buffer (MUSHclient semantics): Tell/ColourTell/Hyperlink
    -- APPEND coloured segments to the current line; Note/ColourNote/AnsiNote/
    -- print FLUSH it as one window line. S&D builds its xcp/cp tables this way
    -- (a row is many Tell/Hyperlink calls terminated by `print("")`), so we
    -- accumulate flat fore,back,text triples and emit a single ColourNote on
    -- flush — otherwise every cell lands on its own line and the table shatters.
    local __snd_seg = {}
    local function __snd_push(fore, back, text)
      __snd_seg[#__snd_seg + 1] = fore or ""
      __snd_seg[#__snd_seg + 1] = back or ""
      __snd_seg[#__snd_seg + 1] = text == nil and "" or tostring(text)
    end
    local function __snd_flush()
      proteles.colourNote(unpack(__snd_seg))
      __snd_seg = {}
    end
    function Tell(s) __snd_push("", "", s) end
    function ColourTell(...)
      local a = {...}
      for i = 1, #a, 3 do __snd_push(a[i], a[i + 1], a[i + 2]) end
    end
    -- Hyperlink(action, text, tooltip, fore, back, ...): native links come
    -- later; keep the coloured text (so clickable cells still render in-line).
    function Hyperlink(action, text, tooltip, fore, back) __snd_push(fore, back, text) end
    function Note(...) __snd_push("", "", table.concat({...}, "\\t")); __snd_flush() end
    function ColourNote(...)
      local a = {...}
      for i = 1, #a, 3 do __snd_push(a[i], a[i + 1], a[i + 2]) end
      __snd_flush()
    end
    function print(...)
      local n, parts = select("#", ...), {}
      for i = 1, n do parts[i] = tostring((select(i, ...))) end
      __snd_push("", "", table.concat(parts, "\\t")); __snd_flush()
    end
    function AnsiNote(s)
      if #__snd_seg > 0 then __snd_flush() end
      proteles.echoAnsi(s)
    end
    -- NoteStyle sets bold/underline for following Notes; we don't carry note
    -- styles, so it's a no-op (output text is unaffected).
    function NoteStyle(...) return 0 end
    -- Simulate: inject text as if received from the MUD (drives S&D's xtest
    -- harness + the `notes` header). The session re-feeds it through the
    -- inbound pipeline so triggers see it and it displays.
    function Simulate(s) proteles.simulate(s == nil and "" or tostring(s)); return 0 end

    -- Colour helpers (MUSHclient world built-ins S&D calls for miniwindow
    -- colours; the native panel uses its own palette, so these only need to
    -- be present + non-nil. ColourNameToRGB returns a BGR int; we parse the
    -- common "#RRGGBB"/name forms loosely and otherwise default).
    function ColourNameToRGB(name)
      if type(name) == "string" then
        local r, g, b = name:match("^#(%x%x)(%x%x)(%x%x)$")
        if r then return tonumber(b .. g .. r, 16) end
      end
      return 0
    end
    function RGBColourToName(rgb)
      local n = tonumber(rgb) or 0
      local b = math.floor(n / 65536) % 256
      local g = math.floor(n / 256) % 256
      local r = n % 256
      return string.format("#%02x%02x%02x", r, g, b)
    end
    function GetNormalColour(which) return 0 end

    -- Variables / identity ---------------------------------------------------
    function GetVariable(name) return proteles.getVar(name) end
    function SetVariable(name, value) proteles.setVar(name, tostring(value)); return 0 end
    function DeleteVariable(name) proteles.deleteVar(name); return 0 end
    function GetPluginID() return proteles.pluginID() end
    function GetInfo(n) return proteles.info(n) end
    function WorldName() return proteles.info(2) or "Aardwolf" end
    function GetPluginInfo(id, n)
      if n == 1 then return "Search_and_Destroy"
      elseif n == 19 then return "5.99"
      elseif n == 20 then return proteles.info(60)
      else return nil end
    end

    -- Connection state --------------------------------------------------------
    function IsConnected() return proteles.isConnected() end

    -- GMCP handler shim: S&D's gmcp(path)/send_gmcp_packet route through
    -- CallPlugin to the GMCP-handler plugin id; we answer from the runtime's
    -- live `proteles.gmcp` table. `gmcpdata_as_string` returns the value at a
    -- dotted path serialised as a Lua literal (what S&D's gmcp() loadstrings).
    local function snd_gmcp_path(s)
      local node = proteles.gmcp
      if s ~= nil and s ~= "" then
        for key in tostring(s):gmatch("[^%.]+") do
          if type(node) ~= "table" then return nil end
          node = node[key]
        end
      end
      return node
    end
    local function snd_lua_literal(v)
      local t = type(v)
      if t == "table" then
        local parts = {}
        for k, val in pairs(v) do
          local key = type(k) == "number" and ("[" .. k .. "]")
            or ("[" .. string.format("%q", tostring(k)) .. "]")
          parts[#parts + 1] = key .. "=" .. snd_lua_literal(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      elseif t == "string" then return string.format("%q", v)
      elseif t == "number" or t == "boolean" then return tostring(v)
      else return "nil" end
    end
    -- gmcphelper convention: a scalar leaf comes back as a STRING. Aardwolf
    -- sends e.g. `char.status.state` as a JSON number, but S&D compares it to
    -- "3" (`is_character_ready`); code that needs a number tonumber()s it. So
    -- quote scalar leaves; tables serialise as a Lua literal.
    function gmcpdata_as_string(s)
      local v = snd_gmcp_path(s)
      local t = type(v)
      if t == "number" or t == "boolean" then return string.format("%q", tostring(v)) end
      return snd_lua_literal(v)
    end
    function Send_GMCP_Packet(s) proteles.sendGMCP(tostring(s)); return 0 end

    -- Inter-plugin ------------------------------------------------------------
    function CallPlugin(id, fn, ...)
      if id == "b6eae87ccedd84f510b74714" then proteles.mapperCall(fn, ...); return 0 end
      if id == "3e7dedbe37e44942dd46d264" then  -- GMCP handler
        if fn == "gmcpdata_as_string" then return 0, gmcpdata_as_string(...) end
        if fn == "Send_GMCP_Packet" then return Send_GMCP_Packet(...) end
        return 0
      end
      return 0, proteles.call(fn, ...)
    end
    function BroadcastPlugin(msg, text) proteles.broadcast(msg, text); return 0 end

    -- Timers / automations: S&D gates its CP/GQ flow by toggling trigger
    -- groups, so these drive the host's own engines (booleanised first).
    function EnableTimer(name, flag) proteles.enableTimer(name, flag and true or false); return 0 end
    function EnableTrigger(name, flag) proteles.enableTrigger(name, flag and true or false); return 0 end
    function EnableGroup(name, flag) proteles.enableGroup(name, flag and true or false); return 0 end
    -- S&D arms/disarms its CP/GQ state machine with EnableTriggerGroup (NOT
    -- EnableGroup) — the spine of campaign/global-quest detection. Route both
    -- group forms to the same engine path.
    function EnableTriggerGroup(name, flag) proteles.enableGroup(name, flag and true or false); return 0 end
    function EnableTimerGroup(name, flag) proteles.enableGroup(name, flag and true or false); return 0 end
    function AddTimer(...) return 0 end
    function DeleteTimer(...) return 0 end
    -- Missing-but-called globals: stub to no-ops so a call can't abort a firing
    -- (these gate secondary features — dynamic scan/consider triggers, a
    -- GQ-check alias edge, diagnostics — wired for real in a follow-up).
    function EnableAlias(name, flag) proteles.enableAlias(name, flag and true or false); return 0 end
    -- Runtime trigger registration → the host's own TriggerEngine. S&D uses
    -- this for its scan/consider matchers. AddTriggerEx args (MUSHclient):
    -- (name, match, response, flags, colour, wildcard, sound, script, send_to, seq)
    function AddTriggerEx(name, match, response, flags, colour, wildcard, sound, script, send_to, seq)
      proteles.addTrigger(name, match, tonumber(flags) or 0, script or "")
      return 0
    end
    function AddTrigger(name, match, response, flags, colour, wildcard, sound, script)
      proteles.addTrigger(name, match, tonumber(flags) or 0, script or "")
      return 0
    end
    function AddAlias(...) return 0 end
    function SetTriggerOption(name, option, value)
      if option == "group" then proteles.setTriggerGroup(name, tostring(value)) end
      return 0
    end
    function DeleteTrigger(...) return 0 end
    function GetTriggerList() return {} end
    function GetTriggerInfo(...) return nil end
    function GetVariableList() return {} end
    function GetPluginVariable(...) return nil end
    function SetClipboard(...) return 0 end

    -- MUSHclient send-target constants (mushclient/OtherTypes.h). S&D passes
    -- e.g. sendto.script to DoAfterSpecial; without this it indexes a nil
    -- global and the calling chunk (e.g. cp_info_end) aborts.
    sendto = {
      world = 0, command = 1, output = 2, status = 3, notepad = 4,
      appendtonotepad = 5, logfile = 6, replacenotepad = 7, commandqueue = 8,
      variable = 9, execute = 10, speedwalk = 11, script = 12, immediate = 13,
      scriptafteromit = 14,
    }

    -- MUSHclient AddTrigger flag bits (mushclient/flags.h). S&D's scan/consider
    -- setup does arithmetic on these (flags = trigger_flag.OmitFromOutput + …),
    -- so they must be present + correct even though AddTriggerEx is currently
    -- a no-op (the dynamic scan/consider triggers are wired for real next).
    trigger_flag = {
      Enabled = 1, OmitFromLog = 2, OmitFromOutput = 4, KeepEvaluating = 8,
      IgnoreCase = 16, RegularExpression = 32, ExpandVariables = 512,
      Replace = 1024, LowercaseWildcard = 2048, Temporary = 16384, OneShot = 32768,
    }

    -- Deferred actions → one-shot timers on the host's own timer engine.
    -- script/scriptafteromit run the text as Lua here; otherwise it's sent to
    -- the MUD. S&D uses these for do_cp_check, area scans, navigation, etc.
    function DoAfterSpecial(seconds, text, sendtoValue)
      local isScript = (sendtoValue == 12 or sendtoValue == 14)
      proteles.doAfter(tonumber(seconds) or 0, tostring(text), isScript)
      return 0
    end
    function DoAfter(seconds, text)
      proteles.doAfter(tonumber(seconds) or 0, tostring(text), false)
      return 0
    end
    function SetStatus(...) end
    function GetOption(...) return 0 end
    function GetAlphaOption(...) return "" end
    function SetOption(...) return 0 end
    function SetAlphaOption(...) return 0 end
    -- Plugin state is persisted by the host lifecycle, not an explicit save;
    -- report success (eOK) so S&D's save paths don't treat it as an error.
    function SaveState(...) return 0 end
    -- Native host: no Windows screen metrics, no colour-picker dialog.
    function GetSystemMetrics(...) return 0 end
    function PickColour(...) return -1 end
    function ReloadPlugin(...) return 0 end

    -- Plugin discovery / misc (stubs — single-plugin curated runtime) --------
    function IsPluginInstalled(id) return false end
    function PluginSupports(id, fn) return false end
    function GetPluginList() return {} end
    function EnablePlugin(id, flag) return 0 end
    function Replace(...) return 0 end
    function Repaint() end
    function Redraw() end
    function SetCursor(...) return 0 end
    function Sound(...) return 0 end
    function PlaySound(...) return 0 end
    function Hash(s) return tostring(s) end
    function FixupHTML(s) return tostring(s) end
    function GetUniqueNumber() return 0 end
    function version_check(...) return true end

    -- String helper -----------------------------------------------------------
    function Trim(s) if s == nil then return "" end return (tostring(s):gsub("^%s*(.-)%s*$", "%1")) end

    -- Bit ops (MUSHclient exposes `bit`; used by hotspot flag tests) ----------
    if bit == nil then
      bit = { band = function(a, b) return 0 end, bor = function(a, b) return 0 end }
    end

    -- os.clock(): on Windows MUSHclient this is WALL time since program start;
    -- on macOS Lua it's CPU time, which barely advances in an idle client and
    -- so wrongly debounces S&D's 1-second `last_cp_check`/`last_gq_check`
    -- guards. `os.time()` (integer seconds) is too coarse: a second `do_cp_check`
    -- ~0.3s later straddles a wall-second boundary, reads a full second later,
    -- escapes the 1s debounce, and resets `cp_check_list` mid-scrape (campaign
    -- target list comes up empty). Use sub-second wall time so the debounce holds.
    os.clock = function() return proteles.monotonic() end

    -- math.random tolerance: S&D's `gmkw` keyword guesser computes
    -- `math.random(2 + round_banker(len*0.5), len)`, whose lower bound exceeds
    -- the upper for short single-word mob names (e.g. "a dog" → "dog", len 3 →
    -- math.random(4, 3)). Standard Lua 5.1 rejects that with "interval is
    -- empty", which aborts `build_main_target_list` mid-run — and a Lua error
    -- discards every effect accumulated in that chunk, including the panel
    -- `publishModel`, so the whole campaign silently fails to appear. `gmkw`
    -- runs for *every* target, so any campaign containing such a mob breaks
    -- detection entirely. Clamp a reversed 2-arg interval (the guess then
    -- degrades to the full word) — leaving the 0/1-arg forms untouched.
    local __snd_orig_random = math.random
    math.random = function(...)
      local a = {...}
      if #a == 2 and type(a[1]) == "number" and type(a[2]) == "number" and a[1] > a[2] then
        a[1] = a[2]
      end
      return __snd_orig_random(unpack(a))
    end

    -- Miniwindow: stubbed (replaced by the native SwiftUI panel). Drawing is a
    -- no-op; geometry queries return 0; `WindowInfo`-style reads return 0.
    local function noop() return 0 end
    for _, name in ipairs({
      "WindowCreate","WindowShow","WindowDelete","WindowResize","WindowPosition",
      "WindowRectOp","WindowCircleOp","WindowLine","WindowText","WindowFont",
      "WindowAddHotspot","WindowDeleteHotspot","WindowMoveHotspot","WindowDragHandler",
      "WindowScrollwheelHandler","WindowMenu","WindowSetPixel","WindowImage",
      "WindowLoadImageMemory","WindowDrawImageAlpha","WindowDeleteAllHotspots",
      "WindowTextWidth","WindowFontInfo","WindowInfo","WindowHotspotInfo",
      "WindowFontList","WindowImageInfo","WindowGetImageAlpha","WindowBlendImage",
      "WindowMergeImageAlpha","WindowFilter","WindowGradient","WindowPolygon",
      "WindowArc","WindowBezier","WindowRectangle","WindowCircle","WindowEllipse",
      "BroadcastPlugin"
    }) do
      if _G[name] == nil then _G[name] = noop end
    end
    function WindowInfo(win, n) return 0 end
    function WindowTextWidth(win, font, text) return 0 end
    function WindowFontInfo(win, font, n) return 0 end
    """

    /// A no-op `movewindow` (the dragging helper) — the native panel handles
    /// placement, so plugins that `require "movewindow"` get a quiet stub.
    static let movewindowStub = """
    local M = {}
    function M.install(win, ...) return { window_left = 0, window_top = 0, width = 0, height = 0 } end
    function M.save_state(...) end
    function M.add_drag_handler(...) end
    function M.add_to_menu(...) end
    return M
    """
}

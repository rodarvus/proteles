import Foundation

/// The core half of the compat-shim Lua source (the other half lives in
/// `LuaRuntime+CompatShimTimers.swift`). Split out of
/// `LuaRuntime+CompatShim.swift` purely for the file-length budget;
/// `automationShimSource` concatenates the two into one Lua chunk.
extension LuaRuntime {
    nonisolated static let shimSourceCore = #"""
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
    -- Restore the stdlib fields the sandbox stripped, so plugins that compute a
    -- path separator from `package.config` or extend `package.path` (a common
    -- idiom for requiring split-out files) don't hit a nil. Unix values: dir-sep
    -- "/", path-sep ";", template "?", … (the `require` loader honours path).
    package.config = package.config or "/\\n;\\n?\\n!\\n-\\n"
    package.path = package.path or "?.lua"
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

    -- MUSHclient flag constants (submodules/mushclient/flags.h). trigger_flag values MUST
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
    -- AddAlias flag bits (submodules/mushclient/flags.h — distinct from trigger bits).
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
    -- MUSHclient send-target constants (submodules/mushclient/OtherTypes.h): sendto.script
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
    -- World options (MUSHclient Get/SetOption + Get/SetAlphaOption + the
    -- GlobalOption family). We don't own MUSHclient's settings model, so this is
    -- a faithful default table (values from the reference OptionsTable) plus a
    -- shim-local write-through: SetOption remembers a value so a later GetOption
    -- round-trips, even though it doesn't change real client behaviour. A few
    -- are pinned to Proteles' truth (utf_8/enable_command_stack/command_stack_
    -- character). Option names are lower-cased + trimmed (MUSHclient FindBaseOption).
    local __numOptDefault = {
      auto_pause = 1, auto_resize_command_window = 0, auto_resize_minimum_lines = 1,
      display_my_input = 1, echo_colour = 0, enable_aliases = 1, enable_beeps = 1,
      enable_command_stack = 1,            -- Proteles stacks commands on ';'
      enable_timers = 1, enable_triggers = 1, line_spacing = 0,
      omit_date_from_save_files = 0, output_font_height = 12,
      play_sounds_in_background = 0, pixel_offset = 1, show_bold = 0,
      tool_tip_visible_time = 5000, underline_hyperlinks = 1, unpause_on_send = 1,
      utf_8 = 1,                           -- Proteles is UTF-8
      wrap_column = 80,
    }
    local __alphaOptDefault = {
      command_stack_character = ";",       -- Proteles' stack separator
      output_font_name = "",               -- resolved live from the host (below)
      script_prefix = "",
    }
    -- Global (app-wide) options are MUSHclient-UI specifics with no Proteles
    -- surface; report their reference defaults (all 0). Keyed lower-case.
    local __globalOptDefault = {
      openactivitywindow = 0, smoothscrolling = 0, smootherscrolling = 0,
    }
    local __numOpt, __alphaOpt = {}, {}    -- SetOption/SetAlphaOption write-through
    local function __optName(n)
      return (tostring(n or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""))
    end
    function GetOption(name)
      local k = __optName(name)
      if __numOpt[k] ~= nil then return __numOpt[k] end
      if __numOptDefault[k] ~= nil then return __numOptDefault[k] end
      return -1                            -- MUSHclient: unknown numeric option
    end
    function SetOption(name, value)
      local k = __optName(name)
      if __numOptDefault[k] == nil then return error_code.eUnknownOption end
      __numOpt[k] = tonumber(value) or 0
      return error_code.eOK
    end
    function GetAlphaOption(name)
      local k = __optName(name)
      if __alphaOpt[k] ~= nil then return __alphaOpt[k] end
      -- output_font_name reports the user's REAL configured output font (pushed
      -- from the app); fall back to the MUSHclient default if not yet set.
      if k == "output_font_name" then
        local font = proteles.outputFontName()
        if font ~= nil and font ~= "" then return font end
        return "FixedSys"
      end
      -- Unknown alpha option: MUSHclient returns nil, but "" is safer for the
      -- common `GetAlphaOption(x) .. y` concatenation and is our long-standing
      -- behaviour, so keep "" for unmodelled names.
      return __alphaOptDefault[k] or ""
    end
    function SetAlphaOption(name, value)
      __alphaOpt[__optName(name)] = tostring(value or "")
      return error_code.eOK
    end
    function GetGlobalOption(name)
      return __globalOptDefault[__optName(name)]  -- nil for unknown (faithful)
    end
    function SetGlobalOption() return error_code.eOK end
    local function __sortedKeys(t)
      local keys = {}
      for k in pairs(t) do keys[#keys + 1] = k end
      table.sort(keys)
      return keys
    end
    function GetOptionList() return __sortedKeys(__numOptDefault) end
    function GetAlphaOptionList() return __sortedKeys(__alphaOptDefault) end
    function GetGlobalOptionList() return __sortedKeys(__globalOptDefault) end
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
    -- TraceOut/SetStatus: MUSHclient's Trace window and status bar have no
    -- Proteles surface, but a generic-shim plugin calling these must not hit a
    -- nil-global. Route the text to the session transcript (a debug capture,
    -- invisible in the scrollback) — SetStatus in particular fires often (e.g. a
    -- per-second countdown), so it must never reach the output.
    function TraceOut(message) proteles.trace("TraceOut: " .. tostring(message or "")) end
    function SetStatus(message) proteles.trace("SetStatus: " .. tostring(message or "")) end
    """#
}

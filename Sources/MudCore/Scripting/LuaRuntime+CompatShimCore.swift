import Foundation

/// The core half of the compat-shim Lua source (the other half lives in
/// `LuaRuntime+CompatShimTimers.swift`). Split out of
/// `LuaRuntime+CompatShim.swift` purely for the file-length budget;
/// `automationShimSource` concatenates the two into one Lua chunk.
extension LuaRuntime {
    internal nonisolated static let shimSourceCore = #"""
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
    -- TraceOut/SetStatus: MUSHclient's Trace window and status bar have no
    -- Proteles surface, but a generic-shim plugin calling these must not hit a
    -- nil-global. Route the text to the session transcript (a debug capture,
    -- invisible in the scrollback) — SetStatus in particular fires often (e.g. a
    -- per-second countdown), so it must never reach the output.
    function TraceOut(message) proteles.trace("TraceOut: " .. tostring(message or "")) end
    function SetStatus(message) proteles.trace("SetStatus: " .. tostring(message or "")) end
    """#
}

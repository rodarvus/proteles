import Foundation

/// The standard helper libraries Aardwolf plugins `require` (ARCHITECTURE.md §7.7),
/// registered with the module loader whenever the compat shim is installed.
///
/// These are clean-room Lua implementations (not copies of the
/// `aardwolfclientpackage` originals) providing the same API the corpus
/// uses. `gmcphelper` is the load-bearing one: its `gmcp(path)` accessor is
/// re-pointed at our native live `proteles.gmcp` table and stringifies leaf
/// scalars, matching what Aardwolf plugins expect (e.g. `gmcp("char.status
/// .state") == "3"`). The bulkier third-party libs (`json`, `serialize`,
/// `aardwolf_colors`) are added as specific plugins need them.
extension LuaRuntime {
    static let standardHelpers: [String: String] = [
        "gmcphelper": gmcpHelperSource,
        "tprint": tprintSource,
        "copytable": copytableSource,
        "commas": commasSource,
        "pairsbykeys": pairsByKeysSource,
        "serialize": serializeSource,
        "var": varSource,
        "json": jsonSource,
        "aardwolf_colors": aardwolfColorsSource,
        "addxml": addxmlSource,
        "telnet_options": telnetOptionsSource,
        "movewindow": movewindowSource
    ]

    /// `telnet_options` (clean-room): the Aardwolf telnet-option constants
    /// (`TELOPT_*`) + `TelnetOption(which, on)` / `TelnetOptionOn` /
    /// `TelnetOptionOff`, which many plugins `dofile(GetInfo(60).."telnet_options
    /// .lua")` to toggle Aardwolf "tag" options (spellup, helps, channels, …).
    /// MUSHclient ships it in the shared plugins dir; Proteles isolates each
    /// plugin, so we provide it as a bundled helper (the `dofile` basename
    /// fallback resolves it). The original sends the option-102 subnegotiation
    /// via `SendPkt`; we route it through `proteles.aardwolfTelnet`, which emits
    /// the exact same `IAC SB 102 <option> <1|2> IAC SE` natively (byte-clean,
    /// no binary round-trip through the Lua↔Swift string bridge). The numeric
    /// option codes are Aardwolf protocol facts.
    private static let telnetOptionsSource = """
    TELOPT_STATMON = 1
    TELOPT_BIGMAP = 2
    TELOPT_HELPS = 3
    TELOPT_MAP = 4
    TELOPT_CHANNELS = 5
    TELOPT_TELLS = 6
    TELOPT_SPELLUP = 7
    TELOPT_SKILLGAINS = 8
    TELOPT_SAYS = 9
    TELOPT_SCORE = 11
    TELOPT_ROOM_NAMES = 12
    TELOPT_EXIT_NAMES = 14
    TELOPT_EDITOR_TAGS = 15
    TELOPT_EQUIPMENT = 16
    TELOPT_INVENTORY = 17
    TELOPT_ROOMDESC_TAGS = 18
    TELOPT_ROOMNAME_TAGS = 19
    TELOPT_INVMON_TAGS = 20
    TELOPT_REPOP_TAGS = 21
    TELOPT_QUIET = 50
    TELOPT_AUTOTICK = 51
    TELOPT_PROMPT = 52
    TELOPT_PAGING = 53
    TELOPT_AUTOMAP = 54
    TELOPT_SHORTMAP = 55
    TELOPT_REQUEST_STATUS = 100

    function TelnetOption(which, on)
      proteles.aardwolfTelnet(which, on and true or false)
    end

    function TelnetOptionOn(which) TelnetOption(which, true) end
    function TelnetOptionOff(which) TelnetOption(which, false) end
    """

    /// `addxml` (clean-room): add triggers/aliases/timers from an attribute
    /// table, the way MUSHclient's `addxml.lua` does — but mapped onto our
    /// compat `AddTriggerEx`/`AddAlias`/`AddTimer` instead of building XML +
    /// `ImportXML`. Same call surface the corpus uses
    /// (`addxml.trigger{ match=…, send=…, … }`). Booleans accept Lua `true`/`1`
    /// or MUSHclient `"y"`/`"n"`. `macro`/`save` degrade gracefully (macros are
    /// a separate feature; `save` needs object introspection we don't expose).
    /// Note: the `group` attribute is accepted but not yet honoured for bulk
    /// `DeleteTriggerGroup` (a separate shim gap).
    private static let addxmlSource = """
    addxml = {}
    local function truthy(v) return v == true or v == 1 or v == "y" or v == "yes" or v == "1" end
    local function falsy(v) return v == false or v == 0 or v == "n" or v == "no" or v == "0" end
    local _seq = 0
    local function autoname(prefix) _seq = _seq + 1; return prefix .. "_addxml_" .. _seq end

    local function triggerFlags(t)
      local f = falsy(t.enabled) and 0 or trigger_flag.Enabled
      if truthy(t.regexp) or truthy(t.regular_expression) then f = f + trigger_flag.RegularExpression end
      if truthy(t.ignore_case) then f = f + trigger_flag.IgnoreCase end
      if truthy(t.keep_evaluating) then f = f + trigger_flag.KeepEvaluating end
      if truthy(t.omit_from_output) then f = f + trigger_flag.OmitFromOutput end
      if truthy(t.omit_from_log) then f = f + trigger_flag.OmitFromLog end
      if truthy(t.expand_variables) then f = f + trigger_flag.ExpandVariables end
      if truthy(t.temporary) then f = f + trigger_flag.Temporary end
      if truthy(t.one_shot) then f = f + trigger_flag.OneShot end
      return f
    end
    function addxml.trigger(t)
      assert(type(t) == "table", "addxml.trigger requires a table")
      local name = t.name or autoname("trigger")
      AddTriggerEx(name, t.match or "", t.send or "", triggerFlags(t),
        custom_colour.NoChange, "", "", t.script or "",
        tonumber(t.send_to) or sendto.world, tonumber(t.sequence) or 100)
      return name
    end

    local function aliasFlags(t)
      local f = falsy(t.enabled) and 0 or alias_flag.Enabled
      if truthy(t.regexp) or truthy(t.regular_expression) then f = f + alias_flag.RegularExpression end
      if truthy(t.ignore_case) then f = f + alias_flag.IgnoreCase end
      if truthy(t.omit_from_output) then f = f + alias_flag.OmitFromOutput end
      if truthy(t.omit_from_log) then f = f + alias_flag.OmitFromLogFile end
      if truthy(t.temporary) then f = f + alias_flag.Temporary end
      if truthy(t.one_shot) then f = f + alias_flag.OneShot end
      return f
    end
    function addxml.alias(t)
      assert(type(t) == "table", "addxml.alias requires a table")
      local name = t.name or autoname("alias")
      AddAlias(name, t.match or "", t.send or "", aliasFlags(t), t.script or "")
      return name
    end

    local function timerFlags(t)
      local f = falsy(t.enabled) and 0 or timer_flag.Enabled
      if truthy(t.one_shot) then f = f + timer_flag.OneShot end
      if truthy(t.temporary) then f = f + timer_flag.Temporary end
      return f
    end
    function addxml.timer(t)
      assert(type(t) == "table", "addxml.timer requires a table")
      local name = t.name or autoname("timer")
      AddTimer(name, tonumber(t.hour) or 0, tonumber(t.minute) or 0, tonumber(t.second) or 0,
        t.send or "", timerFlags(t), t.script or "")
      return name
    end

    function addxml.macro(t) return (type(t) == "table" and t.name) or nil end
    function addxml.save(which, name) return nil end
    return addxml
    """

    /// The load-bearing `aardwolf_colors` functions (clean-room), defined as
    /// globals like MUSHclient's: `strip_colours`, `ColoursToANSI`,
    /// `ColoursToStyles`, `StylesToColours`, plus `StylesToColoursOneLine` and
    /// its `TruncateStyles` helper (a pure styles-table column slice — used by
    /// rsocial capture's whole-line form and mudbin's line-copy column form).
    /// The miniwindow-measuring/drawing functions (`StylesWidth`/`PickStyles`/…)
    /// stay omitted — they need font metrics on a window, not just style data.
    private static let aardwolfColorsSource = """
    local ANSI = {
      k="0;30", r="0;31", g="0;32", y="0;33", b="0;34", m="0;35", c="0;36", w="0;37",
      D="1;30", R="1;31", G="1;32", Y="1;33", B="1;34", M="1;35", C="1;36", W="1;37",
    }
    local RGB = {
      k=0x000000, r=0xAA0000, g=0x00AA00, y=0xAAAA00, b=0x0000AA, m=0xAA00AA, c=0x00AAAA, w=0xAAAAAA,
      D=0x555555, R=0xFF5555, G=0x55FF55, Y=0xFFFF55, B=0x5555FF, M=0xFF55FF, C=0x55FFFF, W=0xFFFFFF,
    }
    local BOLD = { D=true, R=true, G=true, Y=true, B=true, M=true, C=true, W=true }
    local RGB_TO_CODE = {}
    for code, value in pairs(RGB) do RGB_TO_CODE[value] = code end
    local ESC = string.char(27)

    local function xtermRGB(n)
      if n < 8 then return RGB[("krgybmcw"):sub(n + 1, n + 1)]
      elseif n < 16 then return RGB[("DRGYBMCW"):sub(n - 7, n - 7)]
      elseif n < 232 then
        local c = n - 16
        local function v(x) return x == 0 and 0 or (x * 40 + 55) end
        return v(math.floor(c / 36) % 6) * 65536 + v(math.floor(c / 6) % 6) * 256 + v(c % 6)
      else
        local gray = (n - 232) * 10 + 8
        return gray * 65536 + gray * 256 + gray
      end
    end

    -- Walk @-coded text: onText(segment) for visible text, onColour(rgb, bold,
    -- ansi) at each colour code. @@ → @, @- → ~, @x### → xterm, @<c> → colour.
    local function walk(input, onText, onColour)
      local i, n = 1, #input
      local buffer = {}
      local function flush() if #buffer > 0 then onText(table.concat(buffer)); buffer = {} end end
      while i <= n do
        local ch = input:sub(i, i)
        if ch ~= "@" then
          buffer[#buffer + 1] = ch; i = i + 1
        else
          local nxt = input:sub(i + 1, i + 1)
          if nxt == "@" then buffer[#buffer + 1] = "@"; i = i + 2
          elseif nxt == "-" then buffer[#buffer + 1] = "~"; i = i + 2
          elseif nxt == "x" then
            local digits = input:match("^%d%d?%d?", i + 2)
            if digits then
              flush(); onColour(xtermRGB(tonumber(digits)), false, "38;5;" .. digits)
              i = i + 2 + #digits
            else buffer[#buffer + 1] = "@x"; i = i + 2 end
          elseif nxt == "" then i = i + 1
          elseif RGB[nxt] then
            flush(); onColour(RGB[nxt], BOLD[nxt] or false, ANSI[nxt]); i = i + 2
          else i = i + 2 end
        end
      end
      flush()
    end

    function strip_colours(s)
      local out = {}
      walk(s or "", function(t) out[#out + 1] = t end, function() end)
      return table.concat(out)
    end

    function ColoursToANSI(text)
      local out = {}
      walk(text or "",
        function(t) out[#out + 1] = t end,
        function(_, _, ansi) out[#out + 1] = ESC .. "[" .. ansi .. "m" end)
      return table.concat(out) .. ESC .. "[0m"
    end

    function ColoursToStyles(input)
      local styles, rgb, bold = {}, nil, false
      walk(input or "",
        function(t)
          styles[#styles + 1] = {
            text = t, length = #t, textcolour = rgb or 0xAAAAAA, backcolour = 0, bold = bold,
          }
        end,
        function(colour, isBold) rgb = colour; bold = isBold end)
      return styles
    end

    function StylesToColours(styles)
      local out = {}
      for _, style in ipairs(styles or {}) do
        local code = RGB_TO_CODE[style.textcolour]
        if code then out[#out + 1] = "@" .. code end
        out[#out + 1] = (style.text or ""):gsub("@", "@@")
      end
      return table.concat(out)
    end

    -- stylesToANSI: a MUSHclient style-run table → an ANSI string. We round-trip
    -- through our own @-code helpers (StylesToColours then ColoursToANSI), which
    -- is sufficient for the `AnsiNote(stylesToANSI(ColoursToStyles(s)))` idiom
    -- plugins (dinv's dbot.print) use to render coloured output.
    function stylesToANSI(styles)
      return ColoursToANSI(StylesToColours(styles))
    end

    -- TruncateStyles(styles, startcol, endcol): a style-run table sliced to a
    -- 1-based character column range (negatives measure from the end; order of
    -- the bounds doesn't matter). Ported verbatim from aardwolf_colors, with its
    -- copytable.shallow inlined (a style run is a flat table).
    local function shallowStyle(style)
      local copy = {}
      for key, value in pairs(style) do copy[key] = value end
      return copy
    end

    function TruncateStyles(styles, startcol, endcol)
      if (styles == nil) or (styles[1] == nil) then return styles end
      local startcol = startcol or 1
      local endcol = endcol or 99999
      if (startcol < 0) or (endcol < 0) then
        local total_chars = 0
        for _, v in ipairs(styles) do total_chars = total_chars + v.length end
        if startcol < 0 then startcol = total_chars + startcol + 1 end
        if endcol < 0 then endcol = total_chars + endcol + 1 end
      end
      if startcol > endcol then startcol, endcol = endcol, startcol end
      local found_first, col_counter, new_styles, break_after = false, 0, {}, false
      for _, v in ipairs(styles) do
        local new_style = shallowStyle(v)
        col_counter = col_counter + new_style.length
        if endcol <= col_counter then
          local marker = endcol - (col_counter - v.length)
          new_style.text = new_style.text:sub(1, marker)
          new_style.length = marker
          break_after = true
        end
        if startcol <= col_counter then
          if not found_first then
            local marker = startcol - (col_counter - v.length)
            found_first = true
            new_style.text = new_style.text:sub(marker)
            new_style.length = new_style.length - marker + 1
          end
          table.insert(new_styles, new_style)
        end
        if break_after then break end
      end
      return new_styles
    end

    -- StylesToColoursOneLine(styles[, startcol, endcol]): the @-coded string for a
    -- style-run table, optionally truncated to a column range. No range → the
    -- whole line (rsocial capture); with a range → truncated (mudbin line-copy).
    function StylesToColoursOneLine(styles, startcol, endcol)
      if startcol or endcol then
        return StylesToColours(TruncateStyles(styles, startcol, endcol))
      end
      return StylesToColours(styles)
    end

    return true
    """

    /// `serialize.save_simple(value)` → a Lua-source table/value literal;
    /// `serialize.save(name [, value])` → a `name = <literal>` assignment
    /// (looks the value up in the caller's environment when omitted). Restore
    /// with `loadstring(...)()`. No cycle handling (matches `save_simple`'s
    /// contract; sufficient for the flat state tables plugins persist).
    private static let serializeSource = """
    local function isIdentifier(key)
      return type(key) == "string" and key:match("^[%a_][%w_]*$") ~= nil
    end
    local function literal(value)
      local t = type(value)
      if t == "string" then return string.format("%q", value)
      elseif t == "number" or t == "boolean" then return tostring(value)
      elseif t == "table" then
        local parts = {}
        for key, val in pairs(value) do
          local keyText = isIdentifier(key) and key or ("[" .. literal(key) .. "]")
          parts[#parts + 1] = keyText .. "=" .. literal(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
      return "nil"
    end
    -- Global (like MUSHclient's module()) so `require "serialize"` then
    -- `serialize.save(...)` works.
    serialize = {}
    function serialize.save_simple(value) return literal(value) end
    function serialize.save(name, value)
      if value == nil then value = getfenv(2)[name] end
      return name .. " = " .. literal(value)
    end
    return serialize
    """

    /// `var` (clean-room): the MUSHclient `var` table (gammon.com.au forum 4904),
    /// a metatable over `Get/Set/DeleteVariable` so `var.foo = "x"` persists and
    /// `var.foo` reads it back (`var.foo = nil` deletes). The accessors resolve
    /// the global `GetVariable`/`SetVariable`/`DeleteVariable` lazily at call
    /// time, so the compat shim having defined them already is all this needs.
    /// Non-string values are `tostring`'d on write, matching the reference (and
    /// our string-only store); a bad name raises, like the original.
    private static let varSource = """
    var = {}
    setmetatable(var, {
      __index = function(_, name) return GetVariable(name) end,
      __newindex = function(_, name, value)
        local result
        if value == nil then
          result = DeleteVariable(name)
        else
          result = SetVariable(name, tostring(value))
        end
        if result == error_code.eInvalidObjectLabel then
          error("Bad variable name '" .. name .. "'", 2)
        end
      end,
    })
    return var
    """

    /// `json.encode(value)` / `json.decode(text)` over Foundation (via the
    /// `proteles.jsonEncode`/`jsonDecode` host primitives). `json.util` is a
    /// stub — the corpus references it but doesn't call its members.
    private static let jsonSource = """
    json = {
      encode = function(value) return proteles.jsonEncode(value) end,
      decode = function(text) return proteles.jsonDecode(text) end,
      util = {},
    }
    return json
    """

    /// `gmcp(path)` / `gmcpval(path)` over the live `proteles.gmcp` table,
    /// matching the reference gmcphelper (which routes through the GMCP
    /// handler's `gmcpdata_as_string`): **all scalar leaves are stringified**,
    /// recursively, so `gmcp("char.status").state` is `"3"` not `3` — Aardwolf
    /// sends GMCP scalars as JSON numbers, but plugins (dinv, S&D, …) compare
    /// them as strings. A missing path is nil.
    private static let gmcpHelperSource = """
    local function stringifyLeaves(node)
      if type(node) ~= "table" then return tostring(node) end
      local out = {}
      for key, value in pairs(node) do out[key] = stringifyLeaves(value) end
      return out
    end
    local function walk(path)
      local node = proteles.gmcp
      for key in string.gmatch(path or "", "[^.]+") do
        if type(node) ~= "table" then return nil end
        node = node[key]
      end
      return node
    end
    function gmcpval(path)
      local node = walk(path)
      -- Match the reference gmcphelper: a missing path returns "" (an empty
      -- string), not nil — so `gmcp("char.status").state` is harmlessly nil
      -- (string indexing) rather than a nil-index crash, exactly as plugins
      -- written against MUSHclient expect (aard_GMCP_handler: `… or ""`).
      if node == nil then return "" end
      return stringifyLeaves(node)
    end
    gmcp = gmcpval
    function gmcpmessage() return proteles.gmcp end
    return true
    """

    /// `tprint(t)` — pretty-print a table to the output via `Note`.
    private static let tprintSource = """
    function tprint(t, indent)
      indent = indent or ""
      if type(t) ~= "table" then Note(indent .. tostring(t)); return end
      for key, value in pairs(t) do
        if type(value) == "table" then
          Note(indent .. tostring(key) .. ":")
          tprint(value, indent .. "  ")
        else
          Note(indent .. tostring(key) .. " = " .. tostring(value))
        end
      end
    end
    return tprint
    """

    /// `copytable.shallow` / `copytable.deep`.
    private static let copytableSource = """
    local copytable = {}
    function copytable.shallow(t)
      local result = {}
      for key, value in pairs(t) do result[key] = value end
      return result
    end
    function copytable.deep(t)
      if type(t) ~= "table" then return t end
      local result = {}
      for key, value in pairs(t) do result[key] = copytable.deep(value) end
      return result
    end
    return copytable
    """

    /// `movewindow` — the Aardwolf-package miniwindow drag/position helper. It's
    /// a *shared* MUSHclient lib (lives in the global `lua/` dir, not in any
    /// plugin folder), so importing a plugin's `.xml` never brings it and
    /// `require "movewindow"` would fail — breaking any miniwindow plugin
    /// (Aard_Affects and several others). Proteles' native miniwindow overlay
    /// already owns dragging + position persistence, so we provide a quiet stub
    /// (same shape as the S&D host's): `install` returns a neutral position
    /// object and the drag/menu helpers are no-ops. The window is created at the
    /// plugin's default position and the user can drag it; the overlay remembers
    /// where. (Mirrors ``SearchAndDestroyHost/movewindowStub`` for the generic
    /// runtime.)
    private static let movewindowSource = """
    -- Define `movewindow` as a GLOBAL: the real movewindow.lua does
    -- `movewindow = {}` at top level, and plugins call the bare global
    -- `movewindow.install(...)` after a bare `require "movewindow"` that discards
    -- the return (e.g. Aard_Affects). As a bundled helper this runs in the shared
    -- _G, so the global is visible to every plugin via the env __index fallback —
    -- same pattern as gmcphelper's `gmcp`. (Returning it too covers
    -- `local mw = require "movewindow"`.) The native overlay owns dragging, so
    -- install returns a neutral position object and the helpers are no-ops.
    movewindow = movewindow or {}
    function movewindow.install(win, ...)
      return { window_left = 0, window_top = 0, width = 0, height = 0 }
    end
    function movewindow.save_state(...) end
    function movewindow.add_drag_handler(...) end
    function movewindow.add_to_menu(...) end
    return movewindow
    """

    /// `commas(n)` — group a number's integer part with thousands separators.
    private static let commasSource = """
    return function(number)
      local text = tostring(number)
      local sign, int, rest = text:match("^([%-]?)(%d+)(.*)$")
      if not int then return text end
      int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
      return sign .. int .. rest
    end
    """

    /// `pairsByKeys(t [, comparator])` — iterate a table in sorted key order.
    private static let pairsByKeysSource = """
    return function(t, comparator)
      local keys = {}
      for key in pairs(t) do keys[#keys + 1] = key end
      table.sort(keys, comparator)
      local index = 0
      return function()
        index = index + 1
        if keys[index] ~= nil then return keys[index], t[keys[index]] end
      end
    end
    """
}

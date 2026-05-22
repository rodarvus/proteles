import Foundation

/// The standard helper libraries Aardwolf plugins `require` (PLAN.md §7.7),
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
        "json": jsonSource,
        "aardwolf_colors": aardwolfColorsSource
    ]

    /// The load-bearing `aardwolf_colors` functions (clean-room): the 4 the
    /// corpus uses on Aardwolf `@`-colour codes — `strip_colours`,
    /// `ColoursToANSI`, `ColoursToStyles`, `StylesToColours`. Defined as
    /// globals (like MUSHclient's). The miniwindow-drawing functions
    /// (`TruncateStyles`/`StylesWidth`/…) are intentionally omitted.
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

    /// `gmcp(path)` / `gmcpval(path)` over the live `proteles.gmcp` table.
    /// A table node is returned as-is; a leaf scalar is stringified (Aardwolf
    /// plugins compare GMCP values as strings); a missing path is nil.
    private static let gmcpHelperSource = """
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
      if node == nil or type(node) == "table" then return node end
      return tostring(node)
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

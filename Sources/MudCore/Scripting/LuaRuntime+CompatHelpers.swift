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
        "json": jsonSource
    ]

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

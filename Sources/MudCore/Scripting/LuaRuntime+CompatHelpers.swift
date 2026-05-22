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
        "pairsbykeys": pairsByKeysSource
    ]

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

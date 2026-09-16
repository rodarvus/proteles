import Foundation

/// The bundled `gmcphelper` module (ARCHITECTURE.md §7.7), split out of
/// `LuaRuntime+CompatHelpers.swift` for the file-length budget.
///
/// The one thing to understand before touching this file: the Aardwolf package
/// exposes **two different things called `gmcpval`**, and they mean different
/// things.
///
///  1. `CallPlugin("3e7dedbe…", "gmcpval", path)` — a *plugin* entry point on
///     the GMCP handler. It resolves an **absolute** dotted path, returning
///     scalar strings directly or serialising tables (`"room.info"`). Proteles
///     bridges it in `LuaRuntime+CompatShim.swift`; it is not defined here.
///  2. `gmcpval(fieldname)` — the *global* from `gmcphelper.lua`. It looks a
///     field up **relative to the caller's `gmcpdata` global**, which the
///     plugin is expected to have just populated from (1).
///
/// The canonical package idiom chains them:
///
/// ```lua
/// res, arg = CallPlugin("3e7dedbe…", "gmcpval", "room.info")
/// assert(loadstring("gmcpdata = " .. arg))()
/// local num = gmcpval("num")          -- relative to gmcpdata, NOT the root
/// ```
///
/// `aard_GMCP_mapper.xml` uses exactly this (`gmcpval("num")`,
/// `gmcpval("coord.x")`), as does Galaban's Partroxis plugin. Proteles used to
/// collapse the two — `gmcpval` was an alias for `gmcp`, which walks the live
/// `proteles.gmcp` table from the **root** — so `gmcpval("num")` searched for a
/// top-level GMCP package named `num`, found nothing, and returned `""`. Every
/// plugin using the idiom silently got `nil` room ids.
///
/// So `gmcp(path)` (absolute, live) and `gmcpval(field)` (relative to
/// `gmcpdata`) are now separate, as upstream. `get_gmcp`/`get_last_tag`/
/// `gmcpsection`/`gmcpitem` are ported field-for-field from
/// `submodules/aardwolfclientpackage/MUSHclient/lua/gmcphelper.lua` —
/// including its letters-only `%a+` path segmentation and its
/// `serialize.save_simple` return for table results.
extension LuaRuntime {
    /// `gmcphelper`: `gmcp(path)` over the live `proteles.gmcp` table plus the
    /// reference `gmcpval`/`gmcpitem`/`gmcpsection`/`get_gmcp` family over the
    /// caller's `gmcpdata`. Internal (not `private`) because `standardHelpers`
    /// lives in the sibling `LuaRuntime+CompatHelpers.swift`.
    ///
    /// `gmcp(path)` stringifies **all scalar leaves**, recursively, so
    /// `gmcp("char.status").state` is `"3"` not `3` — Aardwolf sends GMCP
    /// scalars as JSON numbers, but plugins (dinv, S&D, …) compare them as
    /// strings. A missing path is `""`.
    static let gmcpHelperSource = """
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
    -- `gmcp(path)`: the live, ABSOLUTE accessor. Upstream this round-trips
    -- through the GMCP handler's `gmcpdata_as_string`; we answer natively.
    function gmcp(path)
      local node = walk(path)
      -- Match the reference gmcphelper: a missing path returns "" (an empty
      -- string), not nil — so `gmcp("char.status").state` is harmlessly nil
      -- (string indexing) rather than a nil-index crash, exactly as plugins
      -- written against MUSHclient expect (aard_GMCP_handler: `… or ""`).
      if node == nil then return "" end
      return stringifyLeaves(node)
    end
    function gmcpmessage() return proteles.gmcp end

    -- The caller's `gmcpdata`. This module loads once into the shared `_G`,
    -- while every plugin runs in its own environment, so a plain global read
    -- here would look in `_G` and never see it. Walk out to the first non-`_G`
    -- environment on the stack — the same `caller_env` scan the module loader
    -- uses, which is what makes this correct by construction: `loadstring`
    -- WRITES `gmcpdata` into `caller_env(2)`, so we read from where it wrote.
    local function caller_gmcpdata()
      for frame = 2, 12 do
        local ok, env = pcall(getfenv, frame)
        if not ok then break end
        if type(env) == "table" and env ~= _G then
          local data = rawget(env, "gmcpdata")
          if data ~= nil then return data end
          break -- the calling plugin has none; don't inherit another's
        end
      end
      return rawget(_G, "gmcpdata")
    end

    function get_last_tag(instr)
      return string.match(instr, "^.*%.(%a+)$") or instr
    end
    function get_gmcp(fieldname, parent)
      assert(fieldname, "nil fieldname passed to get_gmcp")
      assert(parent, "nil parent passed to get_gmcp")
      assert(type(parent) == "table", "non-table parent value passed to get_gmcp")
      local lastval = get_last_tag(fieldname)
      for item in string.gmatch(fieldname, "%a+") do
        if parent[item] == nil then return "" end
        if item == lastval then return parent[item] end
        if type(parent[item]) ~= "table" then return parent[item] end
        parent = parent[item]
      end
      return ""
    end
    function gmcpsection(fieldname, nesting)
      local data = caller_gmcpdata()
      -- Proteles-only degrade path (upstream asserts here). Before `gmcp` and
      -- `gmcpval` were separated, `gmcpval` WAS `gmcp`; a plugin written
      -- against that behaviour passes an absolute path and sets no `gmcpdata`.
      -- Falling back keeps those working — only calls that are broken today
      -- change behaviour.
      if data == nil then return gmcp(fieldname) end
      local outval = get_gmcp(fieldname, data)
      if type(outval) == "table" then
        assert(nesting, "nested table value requested from GMCP. Should be single element.")
        require "serialize"
        return serialize.save_simple(outval)
      end
      if outval == nil or type(outval) == "string" then return outval end
      return tostring(outval)
    end
    -- NOT `return gmcpsection(...)`: a Lua 5.1 tail call REPLACES this frame,
    -- and `getfenv` then reports the collapsed level as the global table — so
    -- `caller_gmcpdata`'s walk would sail past the plugin's environment and
    -- always take the absolute-path fallback. Bind the result first.
    function gmcpval(fieldname)
      local value = gmcpsection(fieldname, true)
      return value
    end
    function gmcpitem(fieldname)
      local value = gmcpsection(fieldname, false)
      return value
    end
    return true
    """
}

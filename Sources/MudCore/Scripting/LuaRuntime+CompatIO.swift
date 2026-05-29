import Foundation

/// A **sandboxed `io` library** for the compat shim. The Lua sandbox removes the
/// real `io` (arbitrary filesystem access); this reintroduces the slice
/// MUSHclient plugins actually use — `io.open`/`io.lines` to read a config/data
/// file, `io.write`/`io.flush` (no-ops) — gated by the same path guard as
/// lsqlite3 (`sqliteAllows`), so a plugin can only touch files inside the
/// `~/Documents/Proteles` tree. Backed by two host primitives, `proteles
/// .readFile`/`proteles.writeFile`, with the Lua-side file objects built on top.
public extension LuaRuntime {
    /// `proteles.readFile(path)` → the file's contents (UTF-8, then Latin-1 for
    /// legacy files), or nil if the path is outside the sandbox or unreadable.
    nonisolated func readFileContents(_ path: String) -> String? {
        guard sqliteAllows(path) else { return nil }
        guard let data = FileManager.default.contents(atPath: normalizedPath(path)) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// `proteles.writeFile(path, content)` → write atomically, returning success.
    /// nil/false if the path is outside the sandbox.
    nonisolated func writeFileAllowed(_ path: String, _ content: String) -> Bool {
        guard sqliteAllows(path) else { return false }
        do {
            try content.write(toFile: normalizedPath(path), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// The Lua `io` library, built over the two host primitives. Installed by
    /// ``loadCompatShim()``.
    internal nonisolated static let ioShimSource = """
    io = {}
    local function __reader(content)
      local pos = 1
      local h = {}
      function h:read(fmt)
        fmt = fmt or "l"
        if type(fmt) == "string" then fmt = fmt:gsub("^%*", "") end
        if pos > #content then return nil end
        if fmt == "a" then local r = content:sub(pos); pos = #content + 1; return r end
        if fmt == "n" then
          local r = content:match("%-?%d+%.?%d*", pos)
          if r then pos = pos + #r end
          return tonumber(r)
        end
        local nl = content:find("\\n", pos, true)
        local line
        if nl then line = content:sub(pos, nl - 1); pos = nl + 1
        else line = content:sub(pos); pos = #content + 1 end
        if fmt == "L" then return line .. "\\n" end
        return line
      end
      function h:lines() return function() return h:read("l") end end
      function h:write() return h end
      function h:flush() return h end
      function h:close() return true end
      return h
    end
    local function __writer(path, existing)
      local buf = existing and { existing } or {}
      local h = {}
      function h:write(...)
        for _, v in ipairs({...}) do buf[#buf + 1] = tostring(v) end
        return h
      end
      function h:lines() return function() return nil end end
      function h:read() return nil end
      function h:flush() proteles.writeFile(path, table.concat(buf)); return h end
      function h:close() proteles.writeFile(path, table.concat(buf)); return true end
      return h
    end
    function io.open(path, mode)
      mode = mode or "r"
      if mode:find("r") then
        local content = proteles.readFile(path)
        if content == nil then return nil, tostring(path) .. ": No such file or directory" end
        return __reader(content)
      end
      local existing = mode:find("a") and proteles.readFile(path) or nil
      return __writer(path, existing)
    end
    function io.lines(path)
      local h, err = io.open(path, "r")
      if not h then error(err or (tostring(path) .. ": cannot open"), 2) end
      return h:lines()
    end
    function io.read() return nil end
    function io.write() return io end
    function io.flush() return io end
    function io.close() return true end
    """
}

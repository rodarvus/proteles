import CLua
import Foundation

/// Controlled `require`/`dofile` for plugins (PLAN.md §7.3/§7.7). The sandbox
/// removes raw `require`/`dofile`/`loadstring`; this reintroduces them in a
/// gated form:
///
/// - `proteles.__moduleSource(name, isRequire)` (Swift) resolves a module
///   name (for `require`) or a path (for `dofile`) to Lua source, but only
///   from the registered bundled libraries and ``moduleSearchPaths`` — never
///   arbitrary filesystem locations.
/// - `proteles.__compile(source, name)` (Swift) compiles source to a Lua
///   function, returned through the existing function-ref bridge.
/// - `require`/`dofile` themselves are defined in Lua (``moduleLoaderBootstrap``)
///   on top of those two primitives, so error reporting stays Lua-side (no
///   `lua_error` longjmp through Swift frames) and the `require` cache is a
///   plain Lua table.
extension LuaRuntime {
    /// Register a helper library available to `require name`.
    public func registerModule(_ name: String, source: String) {
        bundledModules[name] = source
    }

    /// Register several helper libraries at once.
    public func registerModules(_ modules: [String: String]) {
        bundledModules.merge(modules) { _, new in new }
    }

    /// Set the directories `require`/`dofile` may read `.lua` files from.
    public func setModuleSearchPaths(_ paths: [String]) {
        moduleSearchPaths = paths
    }

    // MARK: - Host primitives (called from the Lua bootstrap)

    /// `proteles.__compile(source, name)` → a compiled chunk as a function
    /// ref, or nil (with a red note) on a compile error.
    nonisolated func compileChunk(_ arguments: [LuaValue]) -> [LuaValue] {
        let source = arguments.first?.stringValue ?? ""
        let chunkName = "=" + (arguments.count > 1 ? (arguments[1].stringValue ?? "chunk") : "chunk")
        guard Self.loadBuffer(state, source, name: chunkName) == 0 else {
            effects.append(.note(
                text: "Lua compile error: \(Self.popMessage(state))",
                foreground: "red",
                background: nil
            ))
            return [.nil]
        }
        // The compiled function is on top of the stack; ref it and return the
        // ref (freed at run-end unless the caller keeps the result alive).
        let ref = luaL_ref(state, LUA_REGISTRYINDEX)
        noteTransientRef(ref)
        return [.functionRef(ref)]
    }

    /// `proteles.__moduleSource(name, isRequire)` → resolved Lua source or nil.
    nonisolated func moduleSourceValue(_ arguments: [LuaValue]) -> [LuaValue] {
        let name = arguments.first?.stringValue ?? ""
        let isRequire = arguments.count > 1 ? (arguments[1].booleanValue ?? true) : true
        guard let source = resolveModuleSource(name, isRequire: isRequire) else {
            return [.nil]
        }
        return [.string(source)]
    }

    // MARK: - Resolution

    private nonisolated func resolveModuleSource(_ name: String, isRequire: Bool) -> String? {
        if isRequire {
            if let bundled = bundledModules[name] { return bundled }
            for directory in moduleSearchPaths {
                if let source = readLua(directory + "/" + name + ".lua") { return source }
            }
            return nil
        }
        // dofile: `name` is a path (absolute or relative to a search path).
        for candidate in [name] + moduleSearchPaths.map({ $0 + "/" + name }) {
            if isAllowed(candidate), let source = readLua(candidate) { return source }
        }
        // Fall back to a bundled module matching the file's basename, so a
        // plugin's `dofile("…/aardwolf_colors.lua")` resolves to our built-in.
        let base = (name as NSString).lastPathComponent
        if base.hasSuffix(".lua") {
            return bundledModules[String(base.dropLast(4))]
        }
        return nil
    }

    /// True if `path` resolves inside one of the allowed search roots — the
    /// sandbox boundary for `dofile`.
    private nonisolated func isAllowed(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        return moduleSearchPaths.contains { root in
            let rootPath = (root as NSString).standardizingPath
            return standardized == rootPath || standardized.hasPrefix(rootPath + "/")
        }
    }

    /// Read a `.lua` file, trying UTF-8 then Latin-1 (MUSHclient plugin files
    /// are historically ISO-8859-1).
    private nonisolated func readLua(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Bootstrap

    /// Compile + run a trusted Lua chunk (used for the bootstrap). Errors are
    /// swallowed — the bootstrap source is ours and known-good.
    nonisolated func installModuleLoader() {
        guard Self.loadBuffer(state, Self.moduleLoaderBootstrap, name: "=module_loader") == 0 else {
            clua_pop(state, 1)
            return
        }
        if lua_pcall(state, 0, 0, 0) != 0 { clua_pop(state, 1) }
    }

    /// `luaL_loadbuffer` with the source + a chunk name, leaving the compiled
    /// function (or an error string) on the stack. Returns the status code.
    static func loadBuffer(_ state: OpaquePointer, _ source: String, name: String) -> Int32 {
        source.withCString { sourcePointer in
            name.withCString { namePointer in
                luaL_loadbuffer(state, sourcePointer, source.utf8.count, namePointer)
            }
        }
    }

    /// Defines `require`/`dofile` over the host primitives. The `require`
    /// cache is the local `loaded` table; missing modules raise a Lua error
    /// (caught by the running chunk's pcall).
    nonisolated static let moduleLoaderBootstrap = """
    local loaded = {}
    function require(name)
      local cached = loaded[name]
      if cached ~= nil then return cached end
      local source = proteles.__moduleSource(name, true)
      if source == nil then error("module '" .. tostring(name) .. "' not found", 2) end
      local chunk = proteles.__compile(source, name)
      if chunk == nil then error("error loading module '" .. tostring(name) .. "'", 2) end
      -- Pass the module name as the chunk's vararg, like real `require`, so
      -- modules using `module(...)` (Lua 5.1) get their name.
      local result = chunk(name)
      if result == nil then result = true end
      loaded[name] = result
      return result
    end
    function dofile(path)
      local source = proteles.__moduleSource(path, false)
      if source == nil then error("cannot open '" .. tostring(path) .. "'", 2) end
      local chunk = proteles.__compile(source, path)
      if chunk == nil then error("error loading '" .. tostring(path) .. "'", 2) end
      -- Run the file in the CALLER's environment (like `loadstring` below), so a
      -- plugin's dofile'd modules define their globals in the plugin's own env —
      -- not the shared `_G`. Without this, e.g. dinv's `dinv_init.lua` leaks its
      -- top-level `OnPluginSend` into `_G`, where every *other* plugin that
      -- lacks its own `OnPluginSend` inherits it via `__index` and re-runs it —
      -- so each dinv bypass send was transmitted once per such plugin (doubling).
      setfenv(chunk, getfenv(2))
      return chunk()
    end

    -- Controlled loadstring/load: compile via the host primitive and run the
    -- chunk in the caller's environment (so plugins stay isolated). Returns
    -- nil + message on a compile error, like the stdlib.
    function loadstring(text, chunkname)
      if type(text) ~= "string" then return nil, "loadstring expects a string" end
      local chunk = proteles.__compile(text, chunkname or "loadstring")
      if chunk == nil then return nil, "compile error" end
      setfenv(chunk, getfenv(2))
      return chunk
    end
    load = loadstring
    """
}

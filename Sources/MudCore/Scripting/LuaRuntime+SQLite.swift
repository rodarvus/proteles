import CLSQLite3
import CLua
import Foundation

/// Vendored `lsqlite3` (the `sqlite3` global), exposed to plugins behind a
/// path guard so MUSHclient-compat plugins can read the mapper DB and keep
/// their own SQLite stores — without escaping the sandbox.
///
/// `sqlite3.open(path)` succeeds only for `:memory:` (or an empty/temp path)
/// and files under the per-profile directory set via
/// ``setSQLiteDirectory(_:)``. Everything else is denied (closed by default
/// until a directory is set). The db handle's methods (`exec`, `nrows`,
/// `prepare`, …) run natively — only the open path is validated.
extension LuaRuntime {
    /// Serialises `luaopen_lsqlite3` across all Lua states. lsqlite3 caches its
    /// metatable registry refs in **file-static C globals** (`sqlite_*_meta_ref`)
    /// that it (re)writes on every module-open. Two `LuaRuntime`s opening it
    /// concurrently (e.g. the shared engine + the S&D host on different threads)
    /// race those globals — corrupting a `lua_State` and crashing elsewhere,
    /// non-deterministically. Module-open is fast and once-per-runtime, so a
    /// process-wide lock around it is free and removes the race.
    private static let openLock = NSLock()

    /// Load `lsqlite3` and replace its raw global `sqlite3` with a guarded
    /// wrapper. Called from `init` after the sandbox is applied.
    nonisolated func installSQLite() {
        // Open the C library (serialised — see `openLock`); it leaves its module
        // table on the stack and registers a raw `sqlite3` global. Stash the
        // table, then build the guarded wrapper from it in Lua.
        Self.openLock.lock()
        _ = proteles_open_lsqlite3(UnsafeMutableRawPointer(state))
        Self.openLock.unlock()
        clua_setglobal(state, "__lsqlite3_raw") // pops the module table

        if luaL_loadstring(state, Self.sqliteWrapperScript) == 0 {
            _ = lua_pcall(state, 0, 0, 0)
        } else {
            clua_pop(state, 1) // discard the load error
        }
    }

    /// Normalise a plugin-supplied path for the host filesystem: Windows-centric
    /// plugins (dinv) build paths with `\` separators, which are literal
    /// filename characters on macOS. Treat `\` as `/` so those paths resolve.
    nonisolated func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    /// Whether `sqlite3.open(path)` is permitted. In-memory/temp opens are
    /// always fine; file paths must sit inside the allowed directory.
    nonisolated func sqliteAllows(_ path: String) -> Bool {
        if path.isEmpty || path == ":memory:" { return true }
        guard let directory = sqliteDirectory else { return false }
        let base = URL(fileURLWithPath: directory).standardizedFileURL.path
        let target = URL(fileURLWithPath: normalizedPath(path)).standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    /// Permit `sqlite3.open` for files under `directory` (the per-profile
    /// plugin-data dir). Passing `nil` re-closes file access.
    func setSQLiteDirectory(_ directory: String?) {
        sqliteDirectory = directory
    }

    /// Install the app's `utils.*` dialog provider (see ``ScriptDialogProvider``).
    func setDialogProvider(_ provider: ScriptDialogProvider?) {
        dialogProvider = provider
    }

    /// Install the app's clipboard provider (see ``ClipboardProvider``).
    func setClipboardProvider(_ provider: ClipboardProvider?) {
        clipboardProvider = provider
    }

    /// Install the app's accelerator registrar (plugin `Accelerator`/
    /// `AcceleratorTo` → the live MacroEngine).
    func setAcceleratorRegistrar(_ registrar: (@Sendable (Macro) -> Void)?) {
        acceleratorRegistrar = registrar
    }

    /// `proteles.fileExists(path)` — whether `path` exists, but only within the
    /// allowed directory (the `utils.readdir`/`dbot.fileExists` backing). Paths
    /// outside the sandbox read as "not found" rather than leaking the tree.
    nonisolated func fileExistsAllowed(_ path: String) -> Bool {
        guard sqliteAllows(path) else { return false }
        return FileManager.default.fileExists(atPath: normalizedPath(path))
    }

    /// `proteles.makeDirectory(path)` — create `path` (and intermediates) when
    /// it sits inside the allowed directory; the backing for `utils.shellexecute`
    /// `mkdir` so plugins (dinv) can create their per-character state dir without
    /// a shell. Returns whether the directory exists afterwards.
    nonisolated func makeDirectoryAllowed(_ path: String) -> Bool {
        guard sqliteAllows(path) else { return false }
        let normalized = normalizedPath(path)
        try? FileManager.default.createDirectory(
            atPath: normalized, withIntermediateDirectories: true
        )
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir) && isDir.boolValue
    }

    /// Builds the guarded `sqlite3` global from the raw module + the host
    /// path check, then drops the raw reference.
    private static let sqliteWrapperScript = """
    do
      local raw = __lsqlite3_raw
      __lsqlite3_raw = nil
      local allowed = proteles.sqliteAllowed
      local function checked_open(path, ...)
        -- Windows-centric plugins build paths with backslash separators; treat
        -- them as "/" so the file resolves on macOS (the host guard agrees).
        if type(path) == "string" then path = path:gsub("\\\\", "/") end
        if type(path) == "string" and not allowed(path) then
          error("sqlite3.open: access denied for '" .. path .. "'", 2)
        end
        return raw.open(path, ...)
      end
      sqlite3 = setmetatable({
        open = checked_open,
        open_memory = function(...) return raw.open_memory(...) end,
      }, { __index = raw })  -- constants + other functions
    end
    """
}

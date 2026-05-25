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
    /// Load `lsqlite3` and replace its raw global `sqlite3` with a guarded
    /// wrapper. Called from `init` after the sandbox is applied.
    nonisolated func installSQLite() {
        // Open the C library; it leaves its module table on the stack and
        // registers a raw `sqlite3` global. Stash the table, then build the
        // guarded wrapper from it in Lua.
        _ = proteles_open_lsqlite3(UnsafeMutableRawPointer(state))
        clua_setglobal(state, "__lsqlite3_raw") // pops the module table

        if luaL_loadstring(state, Self.sqliteWrapperScript) == 0 {
            _ = lua_pcall(state, 0, 0, 0)
        } else {
            clua_pop(state, 1) // discard the load error
        }
    }

    /// Whether `sqlite3.open(path)` is permitted. In-memory/temp opens are
    /// always fine; file paths must sit inside the allowed directory.
    nonisolated func sqliteAllows(_ path: String) -> Bool {
        if path.isEmpty || path == ":memory:" { return true }
        guard let directory = sqliteDirectory else { return false }
        let base = URL(fileURLWithPath: directory).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    /// Permit `sqlite3.open` for files under `directory` (the per-profile
    /// plugin-data dir). Passing `nil` re-closes file access.
    func setSQLiteDirectory(_ directory: String?) {
        sqliteDirectory = directory
    }

    /// `proteles.fileExists(path)` — whether `path` exists, but only within the
    /// allowed directory (the `utils.readdir`/`dbot.fileExists` backing). Paths
    /// outside the sandbox read as "not found" rather than leaking the tree.
    nonisolated func fileExistsAllowed(_ path: String) -> Bool {
        guard sqliteAllows(path) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// `proteles.makeDirectory(path)` — create `path` (and intermediates) when
    /// it sits inside the allowed directory; the backing for `utils.shellexecute`
    /// `mkdir` so plugins (dinv) can create their per-character state dir without
    /// a shell. Returns whether the directory exists afterwards.
    nonisolated func makeDirectoryAllowed(_ path: String) -> Bool {
        guard sqliteAllows(path) else { return false }
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Builds the guarded `sqlite3` global from the raw module + the host
    /// path check, then drops the raw reference.
    private static let sqliteWrapperScript = """
    do
      local raw = __lsqlite3_raw
      __lsqlite3_raw = nil
      local allowed = proteles.sqliteAllowed
      local function checked_open(path, ...)
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

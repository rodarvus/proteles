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

    /// Register the mapper overlay merge (D-111) for direct readers in this
    /// runtime: when `sharedDBPath` is opened via `sqlite3.open`, the overlay at
    /// `overlayPath` is ATTACHed and merged temp views are created. Passing nil
    /// for either disables the merge (reverting to a plain single-file read).
    func setMapperOverlay(sharedDBPath: String?, overlayPath: String?) {
        mapperSharedDBPath = sharedDBPath
        mapperOverlayPath = overlayPath
    }

    /// The merge to apply to a freshly-opened DB handle (D-111), as
    /// `(overlayPath, sql)`. Both are `""` when no merge applies — `path` isn't
    /// the shared mapper DB, no overlay is registered, or the overlay file is
    /// missing. `overlayPath` is registered on the connection (via
    /// `db:proteles_allow_attach`) so the authorizer permits exactly this one
    /// ATTACH; `sql` ATTACHes it and creates temp views for overlay-backed
    /// tables. `exits` UNIONs shared cardinal exits (with overlay `exit_locks`
    /// applied) and the overlay's portals/custom exits. `bookmarks` overlays
    /// character notes onto shared notes. Returned to Lua via
    /// `proteles.mapperMergeSQL`.
    nonisolated func mapperMergeSQL(_ path: String) -> (overlay: String, sql: String) {
        guard let shared = mapperSharedDBPath, let overlay = mapperOverlayPath else { return ("", "") }
        let opened = URL(fileURLWithPath: normalizedPath(path)).standardizedFileURL.path
        let sharedStd = URL(fileURLWithPath: shared).standardizedFileURL.path
        guard opened == sharedStd, FileManager.default.fileExists(atPath: overlay) else { return ("", "") }
        let escaped = overlay.replacingOccurrences(of: "'", with: "''")
        let sql = """
        ATTACH DATABASE '\(escaped)' AS personal;
        DROP VIEW IF EXISTS temp.exits;
        CREATE TEMP VIEW exits AS
          SELECT s.dir, s.fromuid, s.touid,
                 COALESCE(l.level, s.level) AS level, s.weight, s.door
            FROM main.exits s
            LEFT JOIN personal.exit_locks l ON l.fromuid = s.fromuid AND l.dir = s.dir
          UNION ALL
          SELECT dir, fromuid, touid, level, weight, door FROM personal.exits;
        DROP VIEW IF EXISTS temp.bookmarks;
        CREATE TEMP VIEW bookmarks AS
          SELECT uid, notes FROM personal.bookmarks
          UNION ALL
          SELECT s.uid, s.notes
            FROM main.bookmarks s
            WHERE NOT EXISTS (
              SELECT 1 FROM personal.bookmarks p WHERE p.uid = s.uid
            );
        """
        return (overlay, sql)
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
      local merge = proteles.mapperMergeSQL
      local function checked_open(path, ...)
        -- Windows-centric plugins build paths with backslash separators; treat
        -- them as "/" so the file resolves on macOS (the host guard agrees).
        if type(path) == "string" then path = path:gsub("\\\\", "/") end
        if type(path) == "string" and not allowed(path) then
          error("sqlite3.open: access denied for '" .. path .. "'", 2)
        end
        local db = raw.open(path, ...)
        -- Mapper overlay merge (D-111): when a direct reader opens the shared
        -- mapper DB, permit + ATTACH the per-character overlay and create merged
        -- views so its unmodified SQL sees the merged set. Empty ⇒ no merge.
        if db and type(path) == "string" then
          local overlay, sql = merge(path)
          if sql ~= "" then
            db:proteles_allow_attach(overlay)  -- authorize this one ATTACH
            db:exec(sql)
          end
        end
        return db
      end
      sqlite3 = setmetatable({
        open = checked_open,
        open_memory = function(...) return raw.open_memory(...) end,
      }, { __index = raw })  -- constants + other functions
    end
    """
}

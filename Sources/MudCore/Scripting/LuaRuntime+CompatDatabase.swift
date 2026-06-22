import Foundation

/// MUSHclient `Database*` world-API family (D3), implemented as a pure-Lua shim
/// over the runtime's already-guarded `sqlite3` global (vendored lsqlite3).
///
/// MUSHclient's model is a **named-handle** wrapper: a plugin calls
/// `DatabaseOpen("name", path, flags)` once and every later call references the
/// DB by that string name, with at most one prepared statement live per name
/// (reference: `submodules/mushclient/scripting/methods/methods_database.cpp`).
/// We keep a `name -> {db, stmt, cols}` registry and map each call onto
/// lsqlite3's object API (`db:prepare`/`stmt:step`/`stmt:get_value`/…).
///
/// Index convention (load-bearing): MUSHclient's Lua column accessors are
/// **1-indexed** (`lua_methods.cpp` `L_DatabaseColumnValue*` use one-relative
/// indices), but lsqlite3's `get_value`/`get_name` are **0-indexed** while its
/// `get_values`/`get_names` already return **1-indexed** arrays. So single-column
/// accessors shift `col-1`; the array accessors pass through.
///
/// The DB file path still goes through the sqlite sandbox (`sqliteAllows`), and
/// the shared-mapper overlay merge applies for free since we open via the same
/// guarded `sqlite3.open`. `DatabaseOpen` `pcall`s the open so a sandbox-denied
/// path returns an error code instead of raising.
extension LuaRuntime {
    nonisolated static let databaseShimSource = #"""
    -- name -> { db = <lsqlite3 handle>, path = <string>, stmt = <vm|nil>, cols = <int> }
    -- A shared global (the shim loads once); keyed by the plugin-chosen name.
    __protelesDatabases = __protelesDatabases or {}
    local function __db(name) return __protelesDatabases[tostring(name)] end
    local function __sqliteTypeFor(value)
      if value == nil then return sqlite3.NULL or 5 end
      local kind = type(value)
      if kind == "number" then
        if value == math.floor(value) then return sqlite3.INTEGER or 1 end
        return sqlite3.FLOAT or 2
      end
      if kind == "string" then return sqlite3.TEXT or 3 end
      return sqlite3.BLOB or 4
    end

    function DatabaseOpen(name, filename, flags)
      name = tostring(name)
      local existing = __protelesDatabases[name]
      if existing then
        if existing.path == filename then return sqlite3.OK end
        return -6 -- already open under this name with a different path
      end
      -- pcall: the guarded sqlite3.open raises on a sandbox-denied path.
      local ok, db, code = pcall(sqlite3.open, tostring(filename))
      if not ok or not db then return code or -1 end
      __protelesDatabases[name] = {
        db = db, path = filename, stmt = nil, cols = 0, validRow = false, types = {}
      }
      return sqlite3.OK
    end

    function DatabaseClose(name)
      local d = __db(name)
      if not d then return -1 end
      if d.stmt then d.stmt:finalize(); d.stmt = nil end
      d.db:close()
      __protelesDatabases[tostring(name)] = nil
      return sqlite3.OK
    end

    function DatabasePrepare(name, sql)
      local d = __db(name)
      if not d then return -1 end
      if d.stmt then return -3 end -- one prepared statement per DB at a time
      local stmt = d.db:prepare(tostring(sql))
      if not stmt then return d.db:errcode() end
      d.stmt = stmt
      d.cols = stmt:columns()
      return sqlite3.OK
    end

    function DatabaseStep(name)
      local d = __db(name)
      if not (d and d.stmt) then return -4 end
      local rc = d.stmt:step() -- raw rc; plugins compare to sqlite3.ROW / sqlite3.DONE
      d.validRow = rc == sqlite3.ROW
      d.types = {}
      if d.validRow then
        for index, value in ipairs(d.stmt:get_values()) do
          d.types[index] = __sqliteTypeFor(value)
        end
      end
      return rc
    end

    function DatabaseFinalize(name)
      local d = __db(name)
      if not d then return -1 end
      if d.stmt then d.stmt:finalize(); d.stmt = nil; d.cols = 0; d.validRow = false; d.types = {} end
      return sqlite3.OK
    end

    function DatabaseReset(name)
      local d = __db(name)
      if not (d and d.stmt) then return -4 end
      d.stmt:reset()
      d.validRow = false
      d.types = {}
      return sqlite3.OK
    end

    function DatabaseColumns(name)
      local d = __db(name)
      return (d and d.cols) or 0
    end

    -- Column NAME is metadata available as soon as the statement is prepared
    -- (MUSHclient's DatabaseColumnName needs no current row). lsqlite3's
    -- single-column get_name bounds against sqlite3_data_count (0 before the
    -- first ROW step → "index out of range"), so read it from get_names()
    -- (sqlite3_column_count-based, valid post-prepare). 1-indexed both sides.
    function DatabaseColumnName(name, col)
      local d = __db(name)
      if not (d and d.stmt) then return nil end
      return d.stmt:get_names()[tonumber(col) or 1]
    end
    -- Single-column value: 1-indexed -> lsqlite3 0-indexed. Requires a current
    -- row (get_value bounds against sqlite3_data_count), as in MUSHclient.
    function DatabaseColumnValue(name, col)
      local d = __db(name)
      if not (d and d.stmt) then return nil end
      return d.stmt:get_value((tonumber(col) or 1) - 1)
    end
    function DatabaseColumnText(name, col)
      local v = DatabaseColumnValue(name, col)
      return v ~= nil and tostring(v) or ""
    end
    function DatabaseColumnType(name, col)
      local d = __db(name)
      if not (d and d.stmt) then return 5 end
      local index = tonumber(col) or 1
      return (d.types and d.types[index]) or 5
    end

    -- Array accessors: lsqlite3 get_values/get_names are already 1-indexed.
    function DatabaseColumnValues(name)
      local d = __db(name)
      if not (d and d.stmt) then return {} end
      return d.stmt:get_values()
    end
    function DatabaseColumnNames(name)
      local d = __db(name)
      if not (d and d.stmt) then return {} end
      return d.stmt:get_names()
    end

    function DatabaseExec(name, sql)
      local d = __db(name)
      if not d then return -1 end
      if d.stmt then return -3 end
      return d.db:exec(tostring(sql))
    end

    function DatabaseError(name)
      local d = __db(name)
      if not d then return "" end
      return d.db:errmsg() or ""
    end

    function DatabaseChanges(name)
      local d = __db(name)
      return (d and d.db:changes()) or 0
    end
    function DatabaseTotalChanges(name)
      local d = __db(name)
      return (d and d.db:total_changes()) or 0
    end

    function DatabaseLastInsertRowid(name)
      local d = __db(name)
      return (d and d.db:last_insert_rowid()) or 0
    end
    function DatabaseInfo(name, infoType)
      local d = __db(name)
      if not d then return nil end
      local n = tonumber(infoType) or 0
      if n == 1 then return d.path end
      if n == 2 then return d.stmt ~= nil end
      if n == 3 then return d.validRow == true end
      if n == 4 then return d.cols or 0 end
      return nil
    end

    -- Convenience: prepare -> step -> first column -> finalize.
    function DatabaseGetField(name, sql)
      local d = __db(name)
      if not d or d.stmt then return nil end
      local stmt = d.db:prepare(tostring(sql))
      if not stmt then return nil end
      local value = nil
      if stmt:step() == sqlite3.ROW then value = stmt:get_value(0) end
      stmt:finalize()
      return value
    end

    function DatabaseList()
      local names = {}
      for key in pairs(__protelesDatabases) do names[#names + 1] = key end
      return names
    end
    """#
}

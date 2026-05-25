----------------------------------------------------------------------------------------------------
-- dinv database module (SQLite)
--
-- Provides database infrastructure for all dinv persistent state.
-- Replaces the serialized Lua table storage (dbot.storage) with SQLite.
--
-- Functions:
--   dinv_db.open()          -- Open/create database, init tables, run migrations
--   dinv_db.close()         -- Close database
--   dinv_db.dbcheck()       -- Check SQLite return code, rollback on error
--   dinv_db.fixsql()        -- Escape string for SQL insertion
--   dinv_db.getPath()       -- Get full path to database file
----------------------------------------------------------------------------------------------------

dinv_db = {}

-- Database handle (nil when closed)
dinv_db.handle = nil


----------------------------------------------------------------------------------------------------
-- Helper functions
----------------------------------------------------------------------------------------------------

-- Check SQLite return code. Returns true on error, false on success.
function dinv_db.dbcheck(code, msg, query)
   if code ~= sqlite3.OK and
      code ~= sqlite3.ROW and
      code ~= sqlite3.DONE then
      local err = (msg or "unknown") ..
                  "\nCODE: " .. (code or "?") ..
                  "\nQUERY: " .. (query or "?")
      if dinv_db.handle then
         dinv_db.handle:exec("ROLLBACK")
      end
      dbot.error("dinv_db: SQL Error: " .. err)
      return true  -- error occurred
   end
   return false  -- no error
end

-- Escape a string for safe SQL insertion. Returns 'escaped_string' or NULL.
function dinv_db.fixsql(s)
   if s then
      return "'" .. (string.gsub(tostring(s), "'", "''")) .. "'"
   else
      return "NULL"
   end
end

-- Execute a function inside a BEGIN/COMMIT transaction.
-- If fn returns a non-success error code, ROLLBACK instead of COMMIT.
-- If fn raises a Lua error, ROLLBACK and re-raise so the DB doesn't get
-- stuck in autocommit-suspended state.  Returns whatever fn returns.
function dinv_db.transaction(fn)
   local db = dinv_db.handle
   if not db then return fn() end

   db:exec("BEGIN")
   local ok, retval = pcall(fn)
   if not ok then
      db:exec("ROLLBACK")
      error(retval, 0)
   end
   if retval ~= DRL_RET_SUCCESS and retval ~= DRL_RET_UNINITIALIZED then
      db:exec("ROLLBACK")
   else
      db:exec("COMMIT")
   end
   return retval
end


-- Convert a number to SQL-safe string. Returns the number or NULL.
function dinv_db.fixnum(n)
   if n ~= nil then
      return tostring(n)
   else
      return "NULL"
   end
end


----------------------------------------------------------------------------------------------------
-- Item column definitions (shared by items, cache_recent tables)
----------------------------------------------------------------------------------------------------

-- Ordered list of stat columns in the items/cache_recent tables.
-- Each entry: { sqlColumn, luaStatField, type }
-- type is "text" or "int" (controls how values are escaped for SQL)
dinv_db.itemStatColumns = {
  { "name",             "name",            "text" },
  { "level",            "level",           "int"  },
  { "weight",           "weight",          "int"  },
  { "wearable",         "wearable",        "text" },
  { "score",            "score",           "int"  },
  { "keywords",         "keywords",        "text" },
  { "type",             "type",            "text" },
  { "worth",            "worth",           "int"  },
  { "flags",            "flags",           "text" },
  { "affect_mods",      "affectmods",      "text" },
  { "material",         "material",        "text" },
  { "found_at",         "foundat",         "text" },
  { "owned_by",         "ownedby",         "text" },
  { "clan",             "clan",            "text" },
  { "spells",           "spells",          "text" },
  { "leads_to",         "leadsto",         "text" },
  { "capacity",         "capacity",        "int"  },
  { "holding",          "holding",         "int"  },
  { "heaviest_item",    "heaviestitem",    "int"  },
  { "items_inside",     "itemsinside",     "int"  },
  { "tot_weight",       "totweight",       "int"  },
  { "item_burden",      "itemburden",      "int"  },
  { "weight_reduction", "weightreduction", "int"  },
  { "str",              "str",             "int"  },
  { "int",              "int",             "int"  },
  { "wis",              "wis",             "int"  },
  { "dex",              "dex",             "int"  },
  { "con",              "con",             "int"  },
  { "luck",             "luck",            "int"  },
  { "hp",               "hp",              "int"  },
  { "mana",             "mana",            "int"  },
  { "moves",            "moves",           "int"  },
  { "hit",              "hit",             "int"  },
  { "dam",              "dam",             "int"  },
  { "allphys",          "allphys",         "int"  },
  { "allmagic",         "allmagic",        "int"  },
  { "acid",             "acid",            "int"  },
  { "cold",             "cold",            "int"  },
  { "energy",           "energy",          "int"  },
  { "holy",             "holy",            "int"  },
  { "electric",         "electric",        "int"  },
  { "negative",         "negative",        "int"  },
  { "shadow",           "shadow",          "int"  },
  { "magic",            "magic",           "int"  },
  { "air",              "air",             "int"  },
  { "earth",            "earth",           "int"  },
  { "fire",             "fire",            "int"  },
  { "light",            "light",           "int"  },
  { "mental",           "mental",          "int"  },
  { "sonic",            "sonic",           "int"  },
  { "water",            "water",           "int"  },
  { "poison",           "poison",          "int"  },
  { "disease",          "disease",         "int"  },
  { "slash",            "slash",           "int"  },
  { "pierce",           "pierce",          "int"  },
  { "bash",             "bash",            "int"  },
  { "ave_dam",          "avedam",          "int"  },
  { "inflicts",         "inflicts",        "text" },
  { "dam_type",         "damtype",         "text" },
  { "weapon_type",      "weapontype",      "text" },
  { "specials",         "specials",        "text" },
  -- AffectMod pseudo-stats (derived from affect_mods text during identification)
  { "sanctuary",        "sanctuary",       "int"  },
  { "haste",            "haste",           "int"  },
  { "flying",           "flying",          "int"  },
  { "invis",            "invis",           "int"  },
  { "regeneration",     "regeneration",    "int"  },
  { "detectinvis",      "detectinvis",     "int"  },
  { "detecthidden",     "detecthidden",    "int"  },
  { "detectevil",       "detectevil",      "int"  },
  { "detectgood",       "detectgood",      "int"  },
  { "detectmagic",      "detectmagic",     "int"  },
  -- Organize query (user-assigned container organization)
  { "organize",         "organize",        "text" },
  -- Item-specific pseudo-stats
  { "dualwield",        "dualwield",       "int"  },
  { "irongrip",         "irongrip",        "int"  },
  { "shield",           "shield",          "int"  },
  { "hammerswing",      "hammerswing",     "int"  },
}

-- Serialize a spells table (array of {level, name, count}) to a string.
-- Format: "level:count:name;level:count:name;..."
function dinv_db.serializeSpells(spellsTable)
  if type(spellsTable) ~= "table" then return nil end
  local parts = {}
  for _, spell in ipairs(spellsTable) do
    table.insert(parts, (spell.level or 0) .. ":" .. (spell.count or 1) .. ":" .. (spell.name or ""))
  end
  return table.concat(parts, ";")
end

-- Deserialize a spells string back to a table (array of {level, name, count}).
function dinv_db.deserializeSpells(spellsStr)
  if type(spellsStr) ~= "string" or spellsStr == "" then return {} end
  local result = {}
  for entry in spellsStr:gmatch("[^;]+") do
    local level, count, name = entry:match("^(%d+):(%d+):(.*)$")
    if level then
      table.insert(result, { level = tonumber(level), count = tonumber(count), name = name })
    end
  end
  return result
end


-- Save a single item to the database (INSERT OR REPLACE).
-- Use this for individual item changes instead of rewriting the entire table.
function dinv_db.saveItem(objId, entry)
  local db = dinv_db.handle
  if not db or not entry then return end

  local query = dinv_db.buildItemInsert("items", objId, entry)
  db:exec(query)
  dinv_db.dbcheck(db:errcode(), db:errmsg(), query)
end

-- Delete a single item from the database.
function dinv_db.deleteItem(objId)
  local db = dinv_db.handle
  if not db then return end

  local query = string.format("DELETE FROM items WHERE obj_id = %s", dinv_db.fixnum(objId))
  db:exec(query)
end


-- Per-row save/delete helpers for the cache tables.  Used by inv.cache.add and
-- inv.cache.remove so mutations are durable immediately instead of waiting for
-- the bulk save that runs in inv.cache.fini -- the bulk path is still used by
-- fini, reset, and config to wholesale rewrite the table.

function dinv_db.saveCacheRecent(objId, entry)
  local db = dinv_db.handle
  if not db or not entry then return end

  local query = dinv_db.buildItemInsert("cache_recent", objId, entry)
  db:exec(query)
  dinv_db.dbcheck(db:errcode(), db:errmsg(), query)
end

function dinv_db.deleteCacheRecent(objId)
  local db = dinv_db.handle
  if not db then return end

  local query = string.format("DELETE FROM cache_recent WHERE obj_id = %s", dinv_db.fixnum(objId))
  db:exec(query)
end

function dinv_db.saveCacheFrequent(cacheKey, entry)
  local db = dinv_db.handle
  if not db or not entry or cacheKey == nil or cacheKey == "" then return end

  local query = dinv_db.buildItemRowInsert(
    "cache_frequent", "cache_key", dinv_db.fixsql(cacheKey), entry)
  db:exec(query)
  dinv_db.dbcheck(db:errcode(), db:errmsg(), query)
end

function dinv_db.deleteCacheFrequent(cacheKey)
  local db = dinv_db.handle
  if not db or cacheKey == nil or cacheKey == "" then return end

  local query = string.format(
    "DELETE FROM cache_frequent WHERE cache_key = %s", dinv_db.fixsql(cacheKey))
  db:exec(query)
end

function dinv_db.saveCacheCustom(objId, entry)
  local db = dinv_db.handle
  if not db or not entry then return end

  local query = string.format(
    "INSERT OR REPLACE INTO cache_custom (obj_id, keywords, organize) VALUES (%s, %s, %s)",
    dinv_db.fixnum(objId),
    dinv_db.fixsql(entry.keywords),
    dinv_db.fixsql(entry.organize))
  db:exec(query)
  dinv_db.dbcheck(db:errcode(), db:errmsg(), query)
end

function dinv_db.deleteCacheCustom(objId)
  local db = dinv_db.handle
  if not db then return end

  local query = string.format(
    "DELETE FROM cache_custom WHERE obj_id = %s", dinv_db.fixnum(objId))
  db:exec(query)
end


-- Replace the disk rows for a single (priorityName, level) entry of inv.set.table.
-- Called by inv.set.createCR after a successful recompute so the just-computed set
-- lands on disk immediately (instead of waiting for the next wholesale inv.set.save).
-- A nil or empty equipSet leaves the rows deleted.
function dinv_db.saveSetLevel(priorityName, level, equipSet)
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec(string.format(
      "DELETE FROM sets WHERE priority_name = %s AND level = %d",
      dinv_db.fixsql(priorityName), level))

    if equipSet then
      for wearLoc, itemData in pairs(equipSet) do
        local query = string.format(
          "INSERT INTO sets (priority_name, level, wear_loc, obj_id, score) VALUES (%s, %d, %s, %s, %s)",
          dinv_db.fixsql(priorityName),
          level,
          dinv_db.fixsql(wearLoc),
          dinv_db.fixnum(itemData.id),
          dinv_db.fixnum(itemData.score))
        db:exec(query)
        if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
          return DRL_RET_INTERNAL_ERROR
        end
      end
    end

    return DRL_RET_SUCCESS
  end)
end


-- Reverse mapping: SQL column name → Lua stat field name (built once at load time)
dinv_db.sqlToLuaStat = {}
for _, colDef in ipairs(dinv_db.itemStatColumns) do
  dinv_db.sqlToLuaStat[colDef[1]] = colDef[2]
end

-- Envelope columns that are not stat fields (handled separately in rowToItemEntry)
dinv_db.envelopeColumns = {
  obj_id = true, cache_key = true, identify_level = true, object_location = true,
  home_container = true, color_name = true,
}


-- SQL-translatable field sets for search pre-filtering.
-- Partial match fields use LIKE '%value%'; all others use exact match or numeric comparison.
dinv_db.partialMatchFields = {
  name = true, leadsto = true, foundat = true,
}

-- Fields that require Lua post-filtering (not translatable to simple SQL).
dinv_db.luaOnlyFields = {
  keywords = true, flags = true, wearable = true, clan = true, spells = true,
  custom = true, rname = true, rloc = true, rlocation = true,
  location = true, loc = true,  -- location uses invFieldObjLoc, not a stat column
  unused = true,                -- queries inv.set.table, not a stat column
}

-- Pre-filter a single query array via SQL. Returns a set (table) of obj_ids
-- that match the SQL-translatable criteria, or nil if no SQL filtering is possible.
-- kvArray is { {key1, val1}, {key2, val2}, ... }
function dinv_db.searchItems(kvArray)
  local db = dinv_db.handle
  if not db then return nil end
  if not kvArray or #kvArray == 0 then return nil end

  local conditions = {}

  for _, kv in ipairs(kvArray) do
    local key = string.lower(kv[1])
    local value = kv[2]
    local valueNum = tonumber(value)

    -- Parse prefix: ~, min, max
    local invert = false
    local prefix = nil
    if key:sub(1, 1) == "~" then
      invert = true
      key = key:sub(2)
    elseif key:sub(1, 3) == "min" then
      prefix = "min"
      key = key:sub(4)
    elseif key:sub(1, 3) == "max" then
      prefix = "max"
      key = key:sub(4)
    end

    -- Skip fields that require Lua handling
    if dinv_db.luaOnlyFields[key] then
      -- Can't translate this criterion to SQL; skip it (Lua will handle it)

    elseif prefix == "min" and valueNum then
      -- Min numeric: column >= value
      local sqlCol = nil
      for sc, lf in pairs(dinv_db.sqlToLuaStat) do
        if lf == key then sqlCol = sc; break end
      end
      if sqlCol then
        table.insert(conditions, sqlCol .. " >= " .. tostring(valueNum))
      end

    elseif prefix == "max" and valueNum then
      -- Max numeric: column <= value
      local sqlCol = nil
      for sc, lf in pairs(dinv_db.sqlToLuaStat) do
        if lf == key then sqlCol = sc; break end
      end
      if sqlCol then
        table.insert(conditions, sqlCol .. " <= " .. tostring(valueNum))
      end

    elseif dinv_db.partialMatchFields[key] then
      -- Partial string match: LIKE '%value%'
      local sqlCol = nil
      for sc, lf in pairs(dinv_db.sqlToLuaStat) do
        if lf == key then sqlCol = sc; break end
      end
      if sqlCol then
        local escaped = value:gsub("'", "''")
        if invert then
          table.insert(conditions, "(" .. sqlCol .. " IS NULL OR " .. sqlCol .. " NOT LIKE '%" .. escaped .. "%')")
        else
          table.insert(conditions, sqlCol .. " LIKE '%" .. escaped .. "%'")
        end
      end

    elseif valueNum then
      -- Numeric exact match
      local sqlCol = nil
      for sc, lf in pairs(dinv_db.sqlToLuaStat) do
        if lf == key then sqlCol = sc; break end
      end
      if sqlCol then
        if invert then
          table.insert(conditions, sqlCol .. " != " .. tostring(valueNum))
        else
          table.insert(conditions, sqlCol .. " = " .. tostring(valueNum))
        end
      end

    else
      -- String exact match (case-insensitive)
      local sqlCol = nil
      for sc, lf in pairs(dinv_db.sqlToLuaStat) do
        if lf == key then sqlCol = sc; break end
      end
      if sqlCol then
        local escaped = value:gsub("'", "''")
        if invert then
          table.insert(conditions, "(" .. sqlCol .. " IS NULL OR LOWER(" .. sqlCol .. ") != LOWER('" .. escaped .. "'))")
        else
          table.insert(conditions, "LOWER(" .. sqlCol .. ") = LOWER('" .. escaped .. "')")
        end
      end
    end
  end

  -- If no conditions were translatable, return nil (caller will do full scan)
  if #conditions == 0 then return nil end

  local query = "SELECT obj_id FROM items WHERE " .. table.concat(conditions, " AND ")
  local candidates = {}
  for row in db:nrows(query) do
    candidates[row.obj_id] = true
  end

  return candidates
end


-- Build an INSERT statement for an item entry into the specified table.
-- entry is the dinv item structure: { identifyLevel, objectLocation, homeContainer, colorName, stats={...} }
-- objId is the item's object ID (integer key)
function dinv_db.buildItemInsert(tableName, objId, entry)
  return dinv_db.buildItemRowInsert(tableName, "obj_id", dinv_db.fixnum(objId), entry)
end

-- Generic variant used by tables that key item rows by something other than obj_id
-- (e.g., cache_frequent keys by normalized basic name in cache_key).  keyValSql must
-- already be SQL-escaped by the caller (use dinv_db.fixsql / dinv_db.fixnum).
function dinv_db.buildItemRowInsert(tableName, keyCol, keyValSql, entry)
  local cols = keyCol .. ", identify_level, object_location, home_container, color_name"
  local vals = string.format("%s, %s, %s, %s, %s",
    keyValSql,
    dinv_db.fixsql(entry.identifyLevel),
    dinv_db.fixsql(entry.objectLocation),
    dinv_db.fixnum(entry.homeContainer),
    dinv_db.fixsql(entry.colorName))

  local stats = entry.stats or {}
  for _, colDef in ipairs(dinv_db.itemStatColumns) do
    local sqlCol   = colDef[1]
    local luaField = colDef[2]
    local colType  = colDef[3]
    local val = stats[luaField]
    if val ~= nil then
      cols = cols .. ", " .. sqlCol
      if luaField == "spells" and type(val) == "table" then
        -- Spells is a nested table — serialize to string
        vals = vals .. ", " .. dinv_db.fixsql(dinv_db.serializeSpells(val))
      elseif colType == "text" then
        vals = vals .. ", " .. dinv_db.fixsql(val)
      else
        vals = vals .. ", " .. dinv_db.fixnum(val)
      end
    end
  end

  return string.format("INSERT OR REPLACE INTO %s (%s) VALUES (%s)", tableName, cols, vals)
end

-- Read a row from db:nrows() and reconstruct a dinv item entry.
-- Returns the entry structure: { identifyLevel, objectLocation, homeContainer, colorName, stats={...} }
-- Optimized: iterates only the columns present in the row (via pairs) rather than all 78 mappings.
function dinv_db.rowToItemEntry(row)
  local entry = {
    identifyLevel  = row.identify_level,
    objectLocation = tonumber(row.object_location) or row.object_location,
    homeContainer  = row.home_container,
    colorName      = row.color_name,
    stats          = {},
  }

  for sqlCol, val in pairs(row) do
    if not dinv_db.envelopeColumns[sqlCol] then
      local luaField = dinv_db.sqlToLuaStat[sqlCol]
      if luaField then
        if luaField == "spells" then
          entry.stats[luaField] = dinv_db.deserializeSpells(val)
        else
          entry.stats[luaField] = val
        end
      end
    end
  end

  return entry
end


----------------------------------------------------------------------------------------------------
-- Database path
----------------------------------------------------------------------------------------------------

-- Returns the directory for the database file.
-- Uses the existing pluginStatePath and character name from GMCP.
function dinv_db.getDir()
   local charName = dbot.gmcp.getName() or "unknown"
   return pluginStatePath .. "\\" .. charName .. "\\"
end

-- Returns the full path to the database file.
function dinv_db.getPath()
   return dinv_db.getDir() .. "dinv.db"
end


----------------------------------------------------------------------------------------------------
-- Table creation
----------------------------------------------------------------------------------------------------

local function init_tables()
   local db = dinv_db.handle
   if not db then return end

   local sql = [[
      CREATE TABLE IF NOT EXISTS items (
         obj_id           INTEGER PRIMARY KEY,
         identify_level   TEXT NOT NULL DEFAULT 'none',
         object_location  TEXT,
         home_container   INTEGER,
         color_name       TEXT,
         name             TEXT,
         level            INTEGER,
         weight           INTEGER,
         wearable         TEXT,
         score            INTEGER,
         keywords         TEXT,
         type             TEXT,
         worth            INTEGER,
         flags            TEXT,
         affect_mods      TEXT,
         material         TEXT,
         found_at         TEXT,
         owned_by         TEXT,
         clan             TEXT,
         spells           TEXT,
         leads_to         TEXT,
         capacity         INTEGER,
         holding          INTEGER,
         heaviest_item    INTEGER,
         items_inside     INTEGER,
         tot_weight       INTEGER,
         item_burden      INTEGER,
         weight_reduction INTEGER,
         str INTEGER, int INTEGER, wis INTEGER,
         dex INTEGER, con INTEGER, luck INTEGER,
         hp INTEGER, mana INTEGER, moves INTEGER,
         hit INTEGER, dam INTEGER,
         allphys INTEGER, allmagic INTEGER,
         acid INTEGER, cold INTEGER, energy INTEGER,
         holy INTEGER, electric INTEGER, negative INTEGER,
         shadow INTEGER, magic INTEGER, air INTEGER,
         earth INTEGER, fire INTEGER, light INTEGER,
         mental INTEGER, sonic INTEGER, water INTEGER,
         poison INTEGER, disease INTEGER,
         slash INTEGER, pierce INTEGER, bash INTEGER,
         ave_dam          INTEGER,
         inflicts         TEXT,
         dam_type         TEXT,
         weapon_type      TEXT,
         specials         TEXT,
         sanctuary INTEGER DEFAULT 0,
         haste INTEGER DEFAULT 0,
         flying INTEGER DEFAULT 0,
         invis INTEGER DEFAULT 0,
         regeneration INTEGER DEFAULT 0,
         detectinvis INTEGER DEFAULT 0,
         detecthidden INTEGER DEFAULT 0,
         detectevil INTEGER DEFAULT 0,
         detectgood INTEGER DEFAULT 0,
         detectmagic INTEGER DEFAULT 0,
         dualwield INTEGER DEFAULT 0,
         irongrip INTEGER DEFAULT 0,
         shield INTEGER DEFAULT 0,
         hammerswing INTEGER DEFAULT 0,
         organize TEXT
      );

      CREATE TABLE IF NOT EXISTS cache_recent (
         obj_id           INTEGER PRIMARY KEY,
         identify_level   TEXT NOT NULL DEFAULT 'none',
         object_location  TEXT,
         home_container   INTEGER,
         color_name       TEXT,
         name             TEXT,
         level            INTEGER,
         weight           INTEGER,
         wearable         TEXT,
         score            INTEGER,
         keywords         TEXT,
         type             TEXT,
         worth            INTEGER,
         flags            TEXT,
         affect_mods      TEXT,
         material         TEXT,
         found_at         TEXT,
         owned_by         TEXT,
         clan             TEXT,
         spells           TEXT,
         leads_to         TEXT,
         capacity         INTEGER,
         holding          INTEGER,
         heaviest_item    INTEGER,
         items_inside     INTEGER,
         tot_weight       INTEGER,
         item_burden      INTEGER,
         weight_reduction INTEGER,
         str INTEGER, int INTEGER, wis INTEGER,
         dex INTEGER, con INTEGER, luck INTEGER,
         hp INTEGER, mana INTEGER, moves INTEGER,
         hit INTEGER, dam INTEGER,
         allphys INTEGER, allmagic INTEGER,
         acid INTEGER, cold INTEGER, energy INTEGER,
         holy INTEGER, electric INTEGER, negative INTEGER,
         shadow INTEGER, magic INTEGER, air INTEGER,
         earth INTEGER, fire INTEGER, light INTEGER,
         mental INTEGER, sonic INTEGER, water INTEGER,
         poison INTEGER, disease INTEGER,
         slash INTEGER, pierce INTEGER, bash INTEGER,
         ave_dam          INTEGER,
         inflicts         TEXT,
         dam_type         TEXT,
         weapon_type      TEXT,
         specials         TEXT,
         sanctuary INTEGER DEFAULT 0,
         haste INTEGER DEFAULT 0,
         flying INTEGER DEFAULT 0,
         invis INTEGER DEFAULT 0,
         regeneration INTEGER DEFAULT 0,
         detectinvis INTEGER DEFAULT 0,
         detecthidden INTEGER DEFAULT 0,
         detectevil INTEGER DEFAULT 0,
         detectgood INTEGER DEFAULT 0,
         detectmagic INTEGER DEFAULT 0,
         dualwield INTEGER DEFAULT 0,
         irongrip INTEGER DEFAULT 0,
         shield INTEGER DEFAULT 0,
         hammerswing INTEGER DEFAULT 0,
         organize TEXT
      );

      CREATE TABLE IF NOT EXISTS cache_custom (
         obj_id   INTEGER PRIMARY KEY,
         keywords TEXT,
         organize TEXT
      );

      CREATE TABLE IF NOT EXISTS cache_frequent (
         cache_key        TEXT PRIMARY KEY,
         identify_level   TEXT NOT NULL DEFAULT 'none',
         object_location  TEXT,
         home_container   INTEGER,
         color_name       TEXT,
         name             TEXT,
         level            INTEGER,
         weight           INTEGER,
         wearable         TEXT,
         score            INTEGER,
         keywords         TEXT,
         type             TEXT,
         worth            INTEGER,
         flags            TEXT,
         affect_mods      TEXT,
         material         TEXT,
         found_at         TEXT,
         owned_by         TEXT,
         clan             TEXT,
         spells           TEXT,
         leads_to         TEXT,
         capacity         INTEGER,
         holding          INTEGER,
         heaviest_item    INTEGER,
         items_inside     INTEGER,
         tot_weight       INTEGER,
         item_burden      INTEGER,
         weight_reduction INTEGER,
         str INTEGER, int INTEGER, wis INTEGER,
         dex INTEGER, con INTEGER, luck INTEGER,
         hp INTEGER, mana INTEGER, moves INTEGER,
         hit INTEGER, dam INTEGER,
         allphys INTEGER, allmagic INTEGER,
         acid INTEGER, cold INTEGER, energy INTEGER,
         holy INTEGER, electric INTEGER, negative INTEGER,
         shadow INTEGER, magic INTEGER, air INTEGER,
         earth INTEGER, fire INTEGER, light INTEGER,
         mental INTEGER, sonic INTEGER, water INTEGER,
         poison INTEGER, disease INTEGER,
         slash INTEGER, pierce INTEGER, bash INTEGER,
         ave_dam          INTEGER,
         inflicts         TEXT,
         dam_type         TEXT,
         weapon_type      TEXT,
         specials         TEXT,
         sanctuary INTEGER DEFAULT 0,
         haste INTEGER DEFAULT 0,
         flying INTEGER DEFAULT 0,
         invis INTEGER DEFAULT 0,
         regeneration INTEGER DEFAULT 0,
         detectinvis INTEGER DEFAULT 0,
         detecthidden INTEGER DEFAULT 0,
         detectevil INTEGER DEFAULT 0,
         detectgood INTEGER DEFAULT 0,
         detectmagic INTEGER DEFAULT 0,
         dualwield INTEGER DEFAULT 0,
         irongrip INTEGER DEFAULT 0,
         shield INTEGER DEFAULT 0,
         hammerswing INTEGER DEFAULT 0,
         organize TEXT
      );

      CREATE TABLE IF NOT EXISTS priorities (
         id   INTEGER PRIMARY KEY AUTOINCREMENT,
         name TEXT NOT NULL UNIQUE
      );

      CREATE TABLE IF NOT EXISTS priority_blocks (
         id          INTEGER PRIMARY KEY AUTOINCREMENT,
         priority_id INTEGER NOT NULL REFERENCES priorities(id),
         block_index INTEGER NOT NULL,
         min_level   INTEGER NOT NULL,
         max_level   INTEGER NOT NULL,
         str REAL DEFAULT 0, int REAL DEFAULT 0, wis REAL DEFAULT 0,
         dex REAL DEFAULT 0, con REAL DEFAULT 0, luck REAL DEFAULT 0,
         dam REAL DEFAULT 0, hit REAL DEFAULT 0,
         avedam REAL DEFAULT 0, offhandDam REAL DEFAULT 0,
         hp REAL DEFAULT 0, mana REAL DEFAULT 0, moves REAL DEFAULT 0,
         sanctuary REAL DEFAULT 0, haste REAL DEFAULT 0,
         flying REAL DEFAULT 0, invis REAL DEFAULT 0,
         regeneration REAL DEFAULT 0,
         detectinvis REAL DEFAULT 0, detecthidden REAL DEFAULT 0,
         detectevil REAL DEFAULT 0, detectgood REAL DEFAULT 0,
         detectmagic REAL DEFAULT 0,
         dualwield REAL DEFAULT 0, irongrip REAL DEFAULT 0,
         shield REAL DEFAULT 0, hammerswing REAL DEFAULT 0,
         maxstr REAL DEFAULT 0, maxint REAL DEFAULT 0, maxwis REAL DEFAULT 0,
         maxdex REAL DEFAULT 0, maxcon REAL DEFAULT 0, maxluck REAL DEFAULT 0,
         allmagic REAL DEFAULT 0, allphys REAL DEFAULT 0,
         bash REAL DEFAULT 0, pierce REAL DEFAULT 0, slash REAL DEFAULT 0,
         acid REAL DEFAULT 0, air REAL DEFAULT 0, cold REAL DEFAULT 0,
         disease REAL DEFAULT 0, earth REAL DEFAULT 0, electric REAL DEFAULT 0,
         energy REAL DEFAULT 0, fire REAL DEFAULT 0, holy REAL DEFAULT 0,
         light REAL DEFAULT 0, magic REAL DEFAULT 0, mental REAL DEFAULT 0,
         negative REAL DEFAULT 0, poison REAL DEFAULT 0, shadow REAL DEFAULT 0,
         sonic REAL DEFAULT 0, water REAL DEFAULT 0,
         excl_lightEq INTEGER DEFAULT 0, excl_head INTEGER DEFAULT 0,
         excl_eyes INTEGER DEFAULT 0, excl_lear INTEGER DEFAULT 0,
         excl_rear INTEGER DEFAULT 0, excl_neck1 INTEGER DEFAULT 0,
         excl_neck2 INTEGER DEFAULT 0, excl_back INTEGER DEFAULT 0,
         excl_medal1 INTEGER DEFAULT 0, excl_medal2 INTEGER DEFAULT 0,
         excl_medal3 INTEGER DEFAULT 0, excl_medal4 INTEGER DEFAULT 0,
         excl_torso INTEGER DEFAULT 0, excl_body INTEGER DEFAULT 0,
         excl_waist INTEGER DEFAULT 0, excl_arms INTEGER DEFAULT 0,
         excl_lwrist INTEGER DEFAULT 0, excl_rwrist INTEGER DEFAULT 0,
         excl_hands INTEGER DEFAULT 0, excl_lfinger INTEGER DEFAULT 0,
         excl_rfinger INTEGER DEFAULT 0, excl_legs INTEGER DEFAULT 0,
         excl_feet INTEGER DEFAULT 0, excl_shield INTEGER DEFAULT 0,
         excl_wielded INTEGER DEFAULT 0, excl_second INTEGER DEFAULT 0,
         excl_hold INTEGER DEFAULT 0, excl_float INTEGER DEFAULT 0,
         excl_above INTEGER DEFAULT 0, excl_portal INTEGER DEFAULT 0,
         excl_sleeping INTEGER DEFAULT 0,
         excl_dam_bash INTEGER DEFAULT 0, excl_dam_pierce INTEGER DEFAULT 0,
         excl_dam_slash INTEGER DEFAULT 0,
         excl_dam_acid INTEGER DEFAULT 0, excl_dam_air INTEGER DEFAULT 0,
         excl_dam_cold INTEGER DEFAULT 0, excl_dam_disease INTEGER DEFAULT 0,
         excl_dam_earth INTEGER DEFAULT 0, excl_dam_electric INTEGER DEFAULT 0,
         excl_dam_energy INTEGER DEFAULT 0, excl_dam_fire INTEGER DEFAULT 0,
         excl_dam_holy INTEGER DEFAULT 0, excl_dam_light INTEGER DEFAULT 0,
         excl_dam_magic INTEGER DEFAULT 0, excl_dam_mental INTEGER DEFAULT 0,
         excl_dam_negative INTEGER DEFAULT 0, excl_dam_poison INTEGER DEFAULT 0,
         excl_dam_shadow INTEGER DEFAULT 0, excl_dam_sonic INTEGER DEFAULT 0,
         excl_dam_water INTEGER DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS sets (
         priority_name TEXT NOT NULL,
         level         INTEGER NOT NULL,
         wear_loc      TEXT NOT NULL,
         obj_id        INTEGER NOT NULL,
         score         REAL,
         PRIMARY KEY (priority_name, level, wear_loc)
      );

      CREATE TABLE IF NOT EXISTS snapshots (
         snapshot_name TEXT NOT NULL,
         wear_loc      TEXT NOT NULL,
         obj_id        INTEGER NOT NULL,
         score         REAL,
         PRIMARY KEY (snapshot_name, wear_loc)
      );

      CREATE TABLE IF NOT EXISTS consumables (
         id        INTEGER PRIMARY KEY AUTOINCREMENT,
         type_name TEXT NOT NULL,
         level     INTEGER,
         name      TEXT,
         room      TEXT,
         full_name TEXT
      );

      CREATE TABLE IF NOT EXISTS stat_bonuses (
         bonus_type  TEXT NOT NULL,
         level       INTEGER NOT NULL,
         stat_name   TEXT NOT NULL,
         current_val INTEGER,
         ave_val     INTEGER,
         max_val     INTEGER,
         PRIMARY KEY (bonus_type, level, stat_name)
      );

      CREATE TABLE IF NOT EXISTS config (
         key   TEXT PRIMARY KEY,
         value TEXT
      );

      CREATE TABLE IF NOT EXISTS migrations (
         version     INTEGER PRIMARY KEY,
         applied_at  INTEGER NOT NULL,
         description TEXT
      );
   ]]

   db:exec(sql)
   if dinv_db.dbcheck(db:errcode(), db:errmsg(), "init_tables") then
      dbot.error("dinv_db: Failed to initialize tables")
   end
end


----------------------------------------------------------------------------------------------------
-- Migrations (for future schema changes)
----------------------------------------------------------------------------------------------------

-- Check if a specific migration version has been applied.
local function migration_applied(version)
   local db = dinv_db.handle
   if not db then return false end

   for row in db:nrows(string.format(
      "SELECT COUNT(*) as cnt FROM migrations WHERE version = %d", version)) do
      return row.cnt > 0
   end
   return false
end

-- Record a migration as applied.
local function record_migration(version, description)
   local db = dinv_db.handle
   if not db then return end

   local query = string.format(
      "INSERT OR IGNORE INTO migrations (version, applied_at, description) VALUES (%d, %d, %s)",
      version, os.time(), dinv_db.fixsql(description))
   db:exec(query)
end

local function run_migrations()
   local db = dinv_db.handle
   if not db then return end

   -- Migration 1: Initial schema creation (recorded in open() for fresh databases)

   -- Migration 2: Add organize column to items and cache_recent tables
   if not migration_applied(2) then
      db:exec("ALTER TABLE items ADD COLUMN organize TEXT")
      db:exec("ALTER TABLE cache_recent ADD COLUMN organize TEXT")
      record_migration(2, "Add organize column to items and cache_recent")
   end

   -- Migration 3: Backfill the affectMod pseudo-stat columns to items and
   -- cache_recent.  These were added directly to init_tables in v3.0016
   -- without an ALTER TABLE migration, so any database first created between
   -- v3.0006 and v3.0015 is missing them and silently fails identify-time
   -- INSERTs that reference them.  Column existence is checked per-table so
   -- the migration is safe on databases that already have the columns
   -- (CREATE TABLE IF NOT EXISTS in init_tables created them on every fresh
   -- install post-v3.0016).
   if not migration_applied(3) then
      local function columnExists(tableName, columnName)
         for row in db:nrows(string.format("PRAGMA table_info(%s)", tableName)) do
            if row.name == columnName then return true end
         end
         return false
      end

      local affectModColumns = {
         "sanctuary", "haste", "flying", "invis", "regeneration",
         "detectinvis", "detecthidden", "detectevil", "detectgood", "detectmagic",
      }

      for _, tableName in ipairs({ "items", "cache_recent" }) do
         for _, columnName in ipairs(affectModColumns) do
            if not columnExists(tableName, columnName) then
               db:exec(string.format(
                  "ALTER TABLE %s ADD COLUMN %s INTEGER DEFAULT 0",
                  tableName, columnName))
            end
         end
      end

      record_migration(3, "Backfill affectMod columns on items and cache_recent")
   end

   -- Migration 4: Purge unidentified (stub) rows from the frequent cache.
   -- The items-table template fallback (v3.0085) could return a none-level
   -- invmon stub and seed it into cache_frequent, where it served as a useless
   -- "template" that double-identified the item on every refresh and was never
   -- overwritten.  v3.0101 stops new stubs from entering the cache; this sweeps
   -- out any that an older build already persisted.
   if not migration_applied(4) then
      db:exec("DELETE FROM cache_frequent WHERE identify_level = 'none'")
      record_migration(4, "Purge none-level stub rows from cache_frequent")
   end

   -- Future migrations go here following this pattern:
   --
   -- if not migration_applied(N) then
   --    db:exec("ALTER TABLE ... ADD COLUMN ...")
   --    record_migration(N, "Description")
   -- end
end


----------------------------------------------------------------------------------------------------
-- Index creation
----------------------------------------------------------------------------------------------------

local function init_indexes()
   local db = dinv_db.handle
   if not db then return end

   local sql = [[
      CREATE INDEX IF NOT EXISTS idx_items_level ON items(level);
      CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);
      CREATE INDEX IF NOT EXISTS idx_items_location ON items(object_location);
      CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);
      CREATE INDEX IF NOT EXISTS idx_cache_recent_level ON cache_recent(level);
      CREATE INDEX IF NOT EXISTS idx_cache_recent_name ON cache_recent(name);
      CREATE INDEX IF NOT EXISTS idx_priority_blocks_pid ON priority_blocks(priority_id);
      CREATE INDEX IF NOT EXISTS idx_sets_priority ON sets(priority_name, level);
      CREATE INDEX IF NOT EXISTS idx_consumables_type ON consumables(type_name);
      CREATE INDEX IF NOT EXISTS idx_stat_bonuses_type ON stat_bonuses(bonus_type, level);
   ]]

   db:exec(sql)
   if dinv_db.dbcheck(db:errcode(), db:errmsg(), "init_indexes") then
      dbot.error("dinv_db: Failed to create indexes")
   end
end


----------------------------------------------------------------------------------------------------
-- Open / Close
----------------------------------------------------------------------------------------------------

function dinv_db.open()
   if dinv_db.handle then
      return true  -- already open
   end

   local dir = dinv_db.getDir()

   -- Create directory if it doesn't exist
   if not dbot.fileExists(dir) then
      dbot.shell('mkdir "' .. dir .. '"')
   end

   local path = dinv_db.getPath()
   local handle, err_msg, err_code = sqlite3.open(path)

   if not handle then
      dbot.error("dinv_db: Failed to open database at " .. path ..
                 ": " .. (err_msg or "unknown error"))
      return false
   end

   dinv_db.handle = handle

   -- Initialize schema
   init_tables()
   run_migrations()
   init_indexes()

   -- Record initial migration if this is a fresh database
   local count = 0
   for row in handle:nrows("SELECT COUNT(*) as cnt FROM migrations") do
      count = row.cnt
   end
   if count == 0 then
      local query = string.format(
         "INSERT INTO migrations (version, applied_at, description) VALUES (1, %d, %s)",
         os.time(), dinv_db.fixsql("Initial schema creation"))
      handle:exec(query)
   end

   return true
end


function dinv_db.close()
   if dinv_db.handle then
      dinv_db.handle:close()
      dinv_db.handle = nil
   end
end

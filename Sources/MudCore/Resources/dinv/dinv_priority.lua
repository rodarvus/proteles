----------------------------------------------------------------------------------------------------
--
-- Inventory priorities
--
-- inv.priority.init.atActive()
-- inv.priority.fini(doSaveState)
--
-- inv.priority.save()
-- inv.priority.load()
-- inv.priority.reset()
--
-- inv.priority.create(priorityName, endTag)
-- inv.priority.clone(origPriorityName, clonedPriorityName, useVerbose, endTag)
-- inv.priority.delete(priorityName, endTag) 
--
-- inv.priority.list(endTag)
-- inv.priority.display(priorityName, endTag)
--
-- inv.priority.edit(priorityName, useAllFields, isQuiet, endTag)
-- inv.priority.update(priorityName, priorityString, isQuiet)
-- inv.priority.copy(priorityName, endTag)
-- inv.priority.paste(priorityName, endTag)
--
-- inv.priority.compare(priorityName1, priorityName2, endTag)
--
-- inv.priority.new(priorityName)
-- inv.priority.add(priorityName, priorityTable)
-- inv.priority.remove(priorityName)
-- inv.priority.get(priorityName, level)
--
-- inv.priority.tableToString(priorityTable, doDisplayUnused, doDisplayColors, doDisplayDesc)
-- inv.priority.stringToTable(priorityString)
--
-- inv.priority.damTypeIsAllowed(damType, priorityName, level)
-- inv.priority.locIsAllowed(wearableLoc, priorityName, level)
-- 
-- inv.priority.addDefault() -- add some default priorities
--
-- Data:
--   inv.priority            = {}
--   inv.priority.table      = {}
--   inv.priority.fieldTable = {}
--
----------------------------------------------------------------------------------------------------

inv.priority           = {}
inv.priority.init      = {}
inv.priority.table     = {}


function inv.priority.init.atActive()
  local retval = DRL_RET_SUCCESS

  retval = inv.priority.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.init.atActive: failed to load priority data from storage: " ..
              dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.priority.init.atActive


function inv.priority.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  if (doSaveState) then
    -- Save our current data
    retval = inv.priority.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.priority.fini: Failed to save inv.priority module data: " ..
                dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- inv.priority.fini


-- Mapping between Lua priority keys and SQL column names.
-- Location exclusions use "excl_" prefix, damtype exclusions use "excl_dam_" prefix.
-- Normal stat weights map to identically-named columns.
inv.priority.luaToSql = {}
inv.priority.sqlToLua = {}

-- Build mapping from inv.priority.fieldTable (populated at load time via dinv_data.lua dofile).
-- This function is called once at the end of this file after fieldTable is defined.
function inv.priority.buildColumnMap()
  -- Location exclusion names (the ~ prefixed keys that disable wear locations)
  local locationExclusions = {
    ["~lightEq"] = true, ["~head"] = true, ["~eyes"] = true, ["~lear"] = true,
    ["~rear"] = true, ["~neck1"] = true, ["~neck2"] = true, ["~back"] = true,
    ["~medal1"] = true, ["~medal2"] = true, ["~medal3"] = true, ["~medal4"] = true,
    ["~torso"] = true, ["~body"] = true, ["~waist"] = true, ["~arms"] = true,
    ["~lwrist"] = true, ["~rwrist"] = true, ["~hands"] = true, ["~lfinger"] = true,
    ["~rfinger"] = true, ["~legs"] = true, ["~feet"] = true, ["~shield"] = true,
    ["~wielded"] = true, ["~second"] = true, ["~hold"] = true, ["~float"] = true,
    ["~above"] = true, ["~portal"] = true, ["~sleeping"] = true,
  }

  for _, entry in ipairs(inv.priority.fieldTable) do
    local luaKey = entry[1]
    local sqlCol

    if locationExclusions[luaKey] then
      -- Location exclusion: ~hold → excl_hold
      sqlCol = "excl_" .. luaKey:sub(2)
    elseif luaKey:sub(1, 1) == "~" then
      -- Damtype exclusion: ~slash → excl_dam_slash
      sqlCol = "excl_dam_" .. luaKey:sub(2)
    else
      -- Normal stat weight: str → str
      sqlCol = luaKey
    end

    inv.priority.luaToSql[luaKey] = sqlCol
    inv.priority.sqlToLua[sqlCol] = luaKey
  end
end


function inv.priority.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  if not inv.priority.table then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM priority_blocks")
    db:exec("DELETE FROM priorities")

    for priorityName, blocks in pairs(inv.priority.table) do
      local query = string.format("INSERT INTO priorities (name) VALUES (%s)",
                                  dinv_db.fixsql(priorityName))
      db:exec(query)
      if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
        dbot.warn("inv.priority.save: Failed to save priority " .. priorityName)
        return DRL_RET_INTERNAL_ERROR
      end

      local priorityId = db:last_insert_rowid()

      for blockIdx, block in ipairs(blocks) do
        local columns = "priority_id, block_index, min_level, max_level"
        local values = string.format("%d, %d, %d, %d",
                                     priorityId, blockIdx,
                                     block.minLevel or 1, block.maxLevel or 291)

        for luaKey, weight in pairs(block.priorities) do
          local sqlCol = inv.priority.luaToSql[luaKey]
          if sqlCol and weight ~= 0 then
            columns = columns .. ", " .. sqlCol
            values = values .. ", " .. tostring(weight)
          end
        end

        query = string.format("INSERT INTO priority_blocks (%s) VALUES (%s)", columns, values)
        db:exec(query)
        if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
          dbot.warn("inv.priority.save: Failed to save priority block for " .. priorityName)
          return DRL_RET_INTERNAL_ERROR
        end
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- inv.priority.save


function inv.priority.load()
  local db = dinv_db.handle
  if not db then
    inv.priority.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any priorities exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM priorities") do
    count = row.cnt
  end

  if count == 0 then
    inv.priority.reset()
    return DRL_RET_SUCCESS
  end

  -- Load all priorities
  inv.priority.table = {}

  for priRow in db:nrows("SELECT id, name FROM priorities") do
    local priorityName = priRow.name
    local priorityId = priRow.id
    inv.priority.table[priorityName] = {}

    -- Load blocks for this priority, ordered by block_index
    local blockQuery = string.format(
      "SELECT * FROM priority_blocks WHERE priority_id = %d ORDER BY block_index", priorityId)

    for blockRow in db:nrows(blockQuery) do
      local block = {
        minLevel = blockRow.min_level,
        maxLevel = blockRow.max_level,
        priorities = {},
      }

      -- Iterate through the SQL-to-Lua mapping to rebuild the priorities table
      for sqlCol, luaKey in pairs(inv.priority.sqlToLua) do
        local val = blockRow[sqlCol]
        if val and val ~= 0 then
          block.priorities[luaKey] = val
        end
      end

      table.insert(inv.priority.table[priorityName], block)
    end
  end

  return DRL_RET_SUCCESS
end -- inv.priority.load


function inv.priority.reset()
  local retval

  inv.priority.table = {}
  retval = inv.priority.addDefault()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.reset: Failed to add default priorities: " .. dbot.retval.getString(retval))
    return retval
  end -- if

  retval = inv.priority.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.priority.reset: Failed to save priorities: " .. dbot.retval.getString(retval))
    return retval
  end -- if

  return retval
end -- inv.priority.reset


function inv.priority.create(priorityName, endTag)
  local retval = DRL_RET_SUCCESS

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.create: priority name is missing!")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.priority.table[priorityName] ~= nil) then
    dbot.warn("inv.priority.create: Priority \"@C" .. priorityName .. "@W\" already exists")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_BUSY)
  end -- if

  retval = inv.priority.new(priorityName)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.create: Failed to add new priority \"@C" .. priorityName .. "@W\": " ..
              dbot.retval.getString(retval))
  else
    retval = inv.priority.edit(priorityName, true, true, endTag)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.priority.create: Failed to edit priority \"@C" .. priorityName .. "@W\": " ..
                dbot.retval.getString(retval))
    else
      dbot.info("Created priority \"@C" .. priorityName .. "@W\"")
    end -- if
  end -- if

  return inv.tags.stop(invTagsPriority, endTag, retval)

end -- inv.priority.create


function inv.priority.clone(origPriorityName, clonedPriorityName, useVerbose, endTag)
  local retval

  if (clonedPriorityName == nil) or (clonedPriorityName == "") then
    dbot.warn("inv.priority.clone: cloned priority name is missing!")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (origPriorityName == nil) or (origPriorityName == "") then
    dbot.warn("inv.priority.clone: original priority name is missing!")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.priority.table[origPriorityName] == nil) then
    dbot.warn("inv.priority.clone: original priority \"@C" .. origPriorityName .. "@W\" does not exist")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  if (inv.priority.table[clonedPriorityName] ~= nil) then
    dbot.warn("inv.priority.clone: cloned priority \"@C" .. clonedPriorityName .. "@W\" already exists") 
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_BUSY)
  end -- if

  -- Copy the priority into a new table entry
  inv.priority.table[clonedPriorityName] = dbot.table.getCopy(inv.priority.table[origPriorityName])

  if useVerbose then
    dbot.info("Cloned priority \"@C" .. clonedPriorityName .. "@W\" from priority \"@C" ..
              origPriorityName .."@W\"")
  end -- if

  -- Save the table with the new priority.  We're done!  :)
  retval = inv.priority.save()

  return inv.tags.stop(invTagsPriority, endTag, retval)

end -- inv.priority.clone


function inv.priority.delete(priorityName, endTag)
  local retval

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.delete: priority name is missing!")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.priority.table[priorityName] == nil) then
    dbot.info("Skipping priority deletion: Priority \"@C" .. priorityName .. "@W\" does not exist")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  retval = inv.priority.remove(priorityName)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.delete: Failed to remove priority \"@C" .. priorityName .. "@W\": " ..
              dbot.retval.getString(retval))
  else
    dbot.info("Deleted priority \"@C" .. priorityName .. "@W\"")
  end -- if

  return inv.tags.stop(invTagsPriority, endTag, retval)
end -- inv.priority.delete


function inv.priority.list(endTag)
  if (inv.priority == nil) or (inv.priority.table == nil) then
    dbot.error("inv.priority.list: Priority table is missing!")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INTERNAL_ERROR)
  end -- if

  -- Alphabetize the priorities before we list them
  local sortedPriorities = {}
  local numPriorities = 0
  for k,_ in pairs(inv.priority.table) do
    table.insert(sortedPriorities, k)
    numPriorities = numPriorities + 1
  end -- for
  table.sort(sortedPriorities, function (v1, v2) return v1 < v2 end)

  if (numPriorities == 0) then
    dbot.info("Priority table is empty")
  else
    dbot.print("@WPriorities:")
    for _, priority in ipairs(sortedPriorities) do
      dbot.print("@W  \"@C" .. priority .. "@W\"@w")
    end -- for
  end -- if

  return inv.tags.stop(invTagsPriority, endTag, DRL_RET_SUCCESS)
end -- inv.priority.list


function inv.priority.display(priorityName, endTag)
  local retval = DRL_RET_SUCCESS

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.display: Missing priorityName parameter") 
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  local priority = inv.priority.table[priorityName]

  if (priority == nil) then
    dbot.info("Priority \"" .. priorityName .. "\" is not in the priority table")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  local priString = inv.priority.tableToString(priority, false, true, true)

  dbot.print("@WPriority: \"@C" .. priorityName .. "@W\"\n")
  dbot.print(priString)

  return inv.tags.stop(invTagsPriority, endTag, retval)
end -- inv.priority.display


function inv.priority.edit(priorityName, useAllFields, isQuiet, endTag)
  local retval = DRL_RET_SUCCESS
  local priorityString = ""

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.edit: priority name is missing!")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.priority.table[priorityName] == nil) then
    dbot.warn("inv.priority.edit: Priority \"@C" .. priorityName .. "@W\" does not exist")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  -- Get a string representation of the priority we want to edit
  priorityString, retval = inv.priority.tableToString(inv.priority.table[priorityName],
                                                      useAllFields, false, useAllFields)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.edit: Failed to get string representation of priority \"@C" ..
              priorityName .. "@W\": " .. dbot.retval.getString(retval))
    return inv.tags.stop(invTagsPriority, endTag, retval)
  end -- if

  local instructions = 
[[Edit your priority!  See "dinv help priority" for more details.

The first column lists the names of each available priority field.  Subsequent columns specify the numeric values of that field for a level range.  You may have as many level ranges as you wish, but ranges should not overlap and they should cover all levels between 1 - 291.
]]

  local fontName = GetAlphaOption("output_font_name")
  if (fontName == nil) then
    fontName = "Consolas"
  end -- if

  -- Use a slightly smaller font if there is lots of info to display
  local fontSize = 12
  if useAllFields then
    fontSize = 10
  end -- if

  repeat
    priorityString = utils.editbox(instructions,
                                   "DINV: Editing priority \"" .. priorityName .. "\"",
                                   priorityString,            -- default text
                                   fontName,                  -- font
                                   fontSize,                  -- font size
                                   { ok_button = "Done!" })   -- extras

    if (priorityString == nil) then
      dbot.info("Cancelled request to edit priority \"@C" .. priorityName .. "@W\"")
      retval = DRL_RET_SUCCESS
      break

    else
      retval = inv.priority.update(priorityName, priorityString, isQuiet)
    end -- if
  until (retval == DRL_RET_SUCCESS)

  return inv.tags.stop(invTagsPriority, endTag, retval)
end -- inv.priority.edit


function inv.priority.update(priorityName, priorityString, isQuiet)

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.update: Missing priority name parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (priorityString == nil) or (priorityString == "") then
    dbot.warn("inv.priority.update: Missing priority string parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  local priorityEntry, retval = inv.priority.stringToTable(priorityString)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("inv.priority.update: Failed to convert priority string into priority: " ..
               dbot.retval.getString(retval))
  else
    inv.priority.table[priorityName] = priorityEntry
    if (not isQuiet) then
      dbot.info("Updated priority \"@C" .. priorityName .. "@W\"")
    end -- if
    inv.priority.save()

    -- Invalidate any previous equipment set analyzis based on this priority.  Sets are
    -- lazy-loaded; without ensureLoaded the in-memory table is the default {} and the
    -- save() below would do a "DELETE FROM sets" followed by inserting nothing, wiping
    -- every priority's analyze data on disk.
    inv.set.ensureLoaded()
    inv.set.table[priorityName] = nil
    inv.set.save()

  end -- if

  return retval
end -- inv.priority.update


function inv.priority.copy(priorityName, endTag)

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.copy: Missing priority name parameter")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.priority.table[priorityName] == nil) then
    dbot.warn("inv.priority.copy: priority \"@C" .. priorityName .. "@W\" does not exist")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  -- Get a string representation of the priority we want to copy
  local priorityString, retval = inv.priority.tableToString(inv.priority.table[priorityName],
                                                            true, false, true)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.copy: Failed to get string representation of priority \"@C" ..
              priorityName .. "@W\": " .. dbot.retval.getString(retval))
  else
    SetClipboard(priorityString)
    dbot.info("Copied priority \"@C" .. priorityName .. "@W\" to clipboard")
  end -- if

  return inv.tags.stop(invTagsPriority, endTag, retval)
end -- inv.priority.copy


function inv.priority.paste(priorityName, endTag)
  local retval = DRL_RET_SUCCESS
  local operation

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.paste: Missing priority name parameter")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.priority.table[priorityName] == nil) then
    operation = "Created"
  else
    operation = "Updated"
  end -- if

  local priorityString = GetClipboard()
  if (priorityString == nil) or (priorityString == "") then
    dbot.warn("inv.priority.paste: Failed to get priority from clipboard")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  retval = inv.priority.update(priorityName, priorityString, true)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.paste: Failed to update priority from clipboard data: " .. 
              dbot.retval.getString(retval))
  else
    dbot.info(operation .. " priority \"@C" .. priorityName .. "@W\" from clipboard data")
  end -- if

  return inv.tags.stop(invTagsPriority, endTag, retval)
end -- inv.priority.paste


function inv.priority.compare(priorityName1, priorityName2, endTag)
  local retval = DRL_RET_SUCCESS

  if (priorityName1 == nil) or (priorityName1 == "") or (priorityName2 == nil) or (priorityName2 == "") then
    dbot.warn("inv.priority.compare: missing priority name")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.priority == nil) or (inv.priority.table == nil) then
    dbot.error("inv.priority.list: Priority table is missing!")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INTERNAL_ERROR)
  end -- if

  if (inv.priority.table[priorityName1] == nil) then
    dbot.warn("inv.priority.compare: Priority \"" .. priorityName1 .. "\" is not present")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  if (inv.priority.table[priorityName2] == nil) then
    dbot.warn("inv.priority.compare: Priority \"" .. priorityName2 .. "\" is not present")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  local startLevel = 1 + 10 * dbot.gmcp.getTier()
  local endLevel = startLevel + 200
  local doPrintHeader = true

  dbot.print("@WSwitching from priority \"@G" .. priorityName1 .. "@W\" to priority \"@G" ..
             priorityName2 .. "@W\" would result in these changes:\n@w")

  for level = startLevel, endLevel do
    local set1 = inv.set.get(priorityName1, level)
    local set2 = inv.set.get(priorityName2, level)
    local didPrintHeader

    if (set1 == nil) then
      dbot.info("Priority \"@C" .. priorityName1 .. "@W\" is missing a set analysis at level " .. level .. ".")
      dbot.info("Please run \"@Gdinv analyze create " .. priorityName1 .. "@W\" before comparing the priority.")
      retval = DRL_RET_MISSING_ENTRY
      break
    elseif (set2 == nil) then
      dbot.info("Priority \"@C" .. priorityName2 .. "@W\" is missing a set analysis at level " .. level .. ".")
      dbot.info("Please run \"@Gdinv analyze create " .. priorityName2 .. "@W\" before comparing the priority.")
      retval = DRL_RET_MISSING_ENTRY
      break
    end -- if

    didPrintHeader, retval = inv.set.displayDiff(set1, set2, level, string.format("Level %3d: ", level),
                                                 doPrintHeader)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.priority.compare: Failed to display priority differences at level " .. level ..
              ": " .. dbot.retval.getString(retval))
      break
    end -- if

    doPrintHeader = not didPrintHeader -- If we already printed a header, don't print one again
  end -- for

  return inv.tags.stop(invTagsPriority, endTag, retval)
end -- inv.priority.compare


function inv.priority.new(priorityName)
  local retval = DRL_RET_SUCCESS

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.new: priority name is missing!")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (inv.priority.table[priorityName] ~= nil) then
    dbot.warn("Skipping request for new priority \"@C" .. priorityName .. "@W\": priority already exists")
    return DRL_RET_INVALID_PARAM
  end -- if

  local priorities = {}
  for _, entry in ipairs(inv.priority.fieldTable) do
    priorities[entry[1]] = 0
  end -- if

  retval = inv.priority.add(priorityName, { { minLevel = 1, maxLevel = 291, priorities = priorities } })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.new: Failed to add priority \"@C" .. priorityName .. "@W\": " ..
              dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.priority.new


function inv.priority.add(priorityName, priorityTable)
  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.add: Missing priorityName parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (priorityTable == nil) then
    dbot.warn("inv.priority.add: priorityTable is nil")
    return DRL_RET_INVALID_PARAM
  end -- if

  inv.priority.table[priorityName] = priorityTable

  local retval = inv.priority.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.priority.add: Failed to save priorities: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.priority.add


function inv.priority.remove(priorityName)
  local retval

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.remove: Missing priorityName parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (inv.priority.table[priorityName] == nil) then
    dbot.warn("inv.priority.remove: Priority table does not contain an entry for priority \"" .. 
            priorityName .. "\"")
    return DRL_RET_MISSING_ENTRY
  end -- if

  inv.priority.table[priorityName] = nil

  retval = inv.priority.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.priority.remove: Failed to save priorities: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.priority.remove


-- Returns table/nil, return value
function inv.priority.get(priorityName, level)

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.get: Missing priorityName parameter")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  local levelNum = tonumber(level or "none")
  if (levelNum == nil) then
    dbot.warn("inv.priority.get: level parameter is not a number")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  local priority = inv.priority.table[priorityName]

  if (priority == nil) then
    dbot.warn("inv.priority.get: Priority \"" .. priorityName .. "\" is not in the priority table")
    return nil, DRL_RET_MISSING_ENTRY
  end -- if

  -- Find the priority block for our level
  local priorityBlock = nil
  for i,v in ipairs(priority) do
    if (levelNum >= v.minLevel) and (levelNum <= v.maxLevel) then
      priorityBlock = v
      break;
    end -- if
  end -- for

  -- Verify that we found an appropriate priority block for our level
  if (priorityBlock == nil) then
    dbot.warn("inv.priority.get: Failed to find a priority block for level " .. 
            levelNum .. " in priority \"" .. priorityName .. "\"")
    return nil
  end -- if

  return priorityBlock.priorities, DRL_RET_SUCCESS

end -- inv.priority.get


-- Returns string, retval
--[[ String format looks something like this:

     Field  L001-  L050-  L100-  L201-
      Name  L049   L099   L200   L299

       int  0.800  0.900  1.000  1.000
       str  1.000  1.000  0.800  0.700
       ...
--]]
function inv.priority.tableToString(priorityTable, doDisplayUnused, doDisplayColors, doDisplayDesc)
  local retval = DRL_RET_SUCCESS
  local generalPrefix, generalSuffix = "", ""
  local fieldPrefix,   fieldSuffix   = "", ""
  local levelPrefix,   levelSuffix   = "", ""
  local descPrefix,    descSuffix    = "", ""

  if doDisplayColors then
    generalPrefix, generalSuffix = "@W", "@w"
    fieldPrefix,   fieldSuffix   = "@C", "@w"
    levelPrefix,   levelSuffix   = "@W", "@W"
    descPrefix,    descSuffix    = "@c", "@w"
  end -- if

  -- Create the first line of the header
  local priString = generalPrefix .. string.format("%12s", "MinLevel")
  for _, blockEntry in ipairs(priorityTable) do
    priString = priString .. string.format("    %s%3d%s", levelPrefix, blockEntry.minLevel, levelSuffix)
  end -- for

  -- Create the second line of the header
  priString = priString .. string.format("\r\n%12s", "MaxLevel")
  for _, blockEntry in ipairs(priorityTable) do
    priString = priString .. string.format("    %s%3d%s", levelPrefix, blockEntry.maxLevel, levelSuffix)
  end -- for
  priString = priString .. "\r\n" .. generalSuffix

  for _, fieldEntry in ipairs(inv.priority.fieldTable) do
    local fieldName = string.lower(fieldEntry[1] or "")
    local fieldDesc = fieldEntry[2]
    local useField = true

    -- "offhandDam" is the only priority field with mixed case (capital D). All other fields are
    -- lowercase. Normalizing to lowercase was considered but rejected — it would require changing
    -- 30+ references across 5 files plus a SQL schema migration, for no functional benefit. This
    -- workaround handles user input that arrives as lowercase "offhanddam" from case-insensitive
    -- parsing, converting it to the canonical "offhandDam" used throughout the codebase.
    if (fieldName == "offhanddam") then
      fieldName = "offhandDam"
    end -- if

    -- Check if we should display this field or not.  We only use the field if at least one entry
    -- block has a non-zero entry for the field or if the doDisplayUnused param is true.
    if (not doDisplayUnused) then
      useField = false

      for _, blockEntry in ipairs(priorityTable) do

        local fieldValue = tonumber(blockEntry.priorities[fieldName] or "")

        if (fieldName == "offhandDam") and (fieldValue == nil) then
          fieldValue = tonumber(blockEntry.priorities["offhanddam"] or "")
        end -- if

        if (fieldValue == nil) then
          fieldValue = 0
        end -- if

        if (fieldValue ~= 0) then
          useField = true
          break
        end -- if
      end -- if
    end -- if

    if (useField) then
      priString = priString .. fieldPrefix .. string.format("\r\n%12s", fieldName) .. fieldSuffix

      for _, blockEntry in ipairs(priorityTable) do
        local fieldValue = tonumber(blockEntry.priorities[fieldName] or "")

        if (fieldName == "offhandDam") and (fieldValue == nil) then
          fieldValue = tonumber(blockEntry.priorities["offhanddam"] or "")
        end -- if

        if (fieldValue == nil) then
          fieldValue = 0
        end -- if

        local valuePrefix, valueSuffix = "", ""

        if doDisplayColors then
          if (fieldValue <= 0) then
            valuePrefix = "@R"
          elseif (fieldValue < 0.5) then
            valuePrefix = "@r"
          elseif (fieldValue < 0.8) then
            valuePrefix = "@y"
          elseif (fieldValue < 1.4) then
            valuePrefix = "@w"
          elseif (fieldValue < 5) then
            valuePrefix = "@g"
          else
            valuePrefix = "@G"
          end -- if

          valueSuffix = "@W"
        end -- if

        priString = priString .. valuePrefix .. string.format("  %5.2f", fieldValue) .. valueSuffix
      end -- for

      if doDisplayDesc then
        priString = priString .. "  : " .. descPrefix .. fieldDesc .. descSuffix
      end -- if
    end -- if
  end -- for  

  return priString, retval
end -- inv.priority.tableToString


-- Returns priority table entry, retval
function inv.priority.stringToTable(priorityString)
  local retval = DRL_RET_SUCCESS
  local priEntry = {}

  if (priorityString == nil) or (priorityString == "") then
    dbot.warn("inv.priority.stringToTable: Missing priority string parameter")
    return priEntry, DRL_RET_INVALID_ENTRY
  end -- if

  local lines = utils.split(priorityString, "\n")

  -- Remove any color codes and comments.  This makes parsing everything much simpler.
  for i, line in ipairs(lines) do
    lines[i] = string.gsub(strip_colours(line), ":.*$", "")
  end -- for

  -- Verify the integrity of the string table.  Each line should have the same number
  -- of columns.
  local numColumns = nil
  for i, line in ipairs(lines) do
    local words, retval = dbot.wordsToArray(line)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.priority.stringToTable: Failed to convert line into array: " .. 
                dbot.retval.getString(retval))
      return priEntry, retval
    end -- if

    -- Remove any lines containing only white space.  Those just complicate things...
    if (#words == 0) then
      table.remove(lines, i)

    elseif (numColumns == nil) then
      numColumns = #words

    elseif (numColumns ~= #words) then
      dbot.warn("Malformed line has wrong number of columns:\n\"" .. line .. "\"")
      return priEntry, DRL_RET_INVALID_PARAM
    end -- if
  end -- for

  if (numColumns == nil) then
    dbot.warn("No valid lines were detected in the priority")
      return priEntry, DRL_RET_INVALID_PARAM
  elseif (numColumns < 2) then
    dbot.warn("Missing one or more columns in the priority")
      return priEntry, DRL_RET_INVALID_PARAM
  end -- if

  -- Parse the header lines
  if (#lines < 2) then
    dbot.warn("Missing header lines in priority")
    return priEntry, DRL_RET_INVALID_PARAM
  end -- if

  local header1, retval = dbot.wordsToArray(lines[1])
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("The priority's first line (part of the header) is malformed: " ..
              dbot.retval.getString(retval))
    return priEntry, retval
  end -- if

  if (string.lower(header1[1] or "") ~= "minlevel") then
    dbot.warn("Missing or malformed minLevel header line in priority")
    return priEntry, DRL_RET_INVALID_PARAM
  end -- if  

  local header2, retval = dbot.wordsToArray(lines[2])
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("The priority's second line (part of the header) is malformed: " ..
              dbot.retval.getString(retval))
    return priEntry, retval
  end -- if

  if (string.lower(header2[1] or "") ~= "maxlevel") then
    dbot.warn("Missing or malformed maxLevel header line in priority")
    return priEntry, DRL_RET_INVALID_PARAM
  end -- if  

  -- Set up the initial block entries and level ranges
  for i = 2, numColumns do -- Skip the first column (min/max levels and the field names)
    local _, _, minLevel = string.find(header1[i], "(%d+)")
    local _, _, maxLevel = string.find(header2[i], "(%d+)")
    minLevel = tonumber(minLevel or "") or 0
    maxLevel = tonumber(maxLevel or "") or 0

    -- Ensure that there aren't any gaps in the level ranges.  The minLevel for this block
    -- should be exactly one more than the maxLevel from the previous block.
    if (#priEntry > 0) and (priEntry[#priEntry].maxLevel + 1 ~= minLevel) then
      dbot.warn("Detected level gap between consecutive priority blocks\n" ..
                "     Previous level block [" .. priEntry[#priEntry].minLevel .. "-" .. 
                priEntry[#priEntry].maxLevel .. "], current level block [" .. minLevel .. "-" ..
                maxLevel .. "]")
      return priEntry, DRL_RET_INVALID_PARAM
    end -- if

    table.insert(priEntry, { minLevel = minLevel, maxLevel = maxLevel, priorities = {} })
  end -- for

  -- The priority must start at level 1 and end at 291
  if (priEntry[1].minLevel ~= 1) or (priEntry[#priEntry].maxLevel ~= 291) then
    dbot.warn("Priority must start at level 1 and continue to level 291")
    return priEntry, DRL_RET_INVALID_PARAM
  end -- if

  -- For each priority field, add the field's value to each block entry
  for i = 3, #lines do
    local fieldLine, retval = dbot.wordsToArray(lines[i])
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("Failed to parse priority line \"" .. lines[i] .. "\"")
      return priEntry, DRL_RET_INVALID_PARAM
    end -- if

    if (#fieldLine > 0) then
      -- Verify that the field name is valid
      local fieldName = string.lower(fieldLine[1] or "")
      local fieldIsValid = false
      for _, entry in ipairs(inv.priority.fieldTable) do
        if (string.lower(entry[1] or "") == fieldName) then 
          fieldIsValid = true
          break
        end -- if
      end -- if
      if (not fieldIsValid) then
        dbot.warn("Unsupported priority field \"" .. (fieldName or "nil") .. "\" in line\n     \"" ..
                  (lines[i] or "nil") .. "\"")
        return priEntry, DRL_RET_INVALID_PARAM
      end -- if

      for blockIdx, priorityBlock in ipairs(priEntry) do
        local fieldValueRaw = fieldLine[blockIdx + 1]  -- add one to skip over the field name
        if (fieldValueRaw == nil) then
          dbot.warn("Missing one or more columns for priority field \"" .. fieldName .. "\"")
          return priEntry, DRL_RET_INVALID_PARAM
        end -- if

        local fieldValue = tonumber(fieldValueRaw or "")
        if (fieldValue == nil) then
          dbot.warn("Non-numeric field value in priority at column " .. blockIdx + 1 ..
                    " in line\n     \"" .. lines[i] .. "\"")
          return priEntry, DRL_RET_INVALID_PARAM
        end -- if

        -- See comment in tableToString for why offhandDam keeps its mixed case.
        if (fieldName == "offhanddam") then
          fieldName = "offhandDam"
        end -- if

        priorityBlock.priorities[fieldName] = fieldValue
      end -- for
    end -- if

  end -- for

  return priEntry, retval
end -- inv.priority.stringToTable


-- Priorities can have lines of the form "~pierce 1 0 0 1 1" to indicate that
-- weapons with the "pierce" damtype should be ignored when creating the priority
-- equipment sets
function inv.priority.damTypeIsAllowed(damType, priorityName, level)
  if (damType == nil) or (damType == "") then
    dbot.warn("inv.priority.damTypeIsAllowed: Missing damType parameter")
    return false
  end -- if

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.damTypeIsAllowed: Missing priority name parameter")
    return false
  end -- if

  level = tonumber(level or "")
  if (level == nil) or (level < 1) or (level > 291) then
    dbot.warn("inv.priority.damTypeIsAllowed: Invalid level parameter")
    return false
  end -- if

  -- Check if the specified priority exists for the specified level
  local priorityTable, retval = inv.priority.get(priorityName, level)
  if (priorityTable == nil) then
    dbot.warn("inv.priority.damTypeIsAllowed: Priority \"" .. priorityName ..
              "\" does not have a priority table " .. "for level " .. level)
    return false
  end -- if

  local value = tonumber(priorityTable["~" .. (string.lower(damType) or "")] or "") or 0
  if (value == 0) then
    return true
  else
    return false
  end -- if  

end -- inv.priority.damTypeIsAllowed


-- Priorities can have lines of the form "~hold 1 0 0 1 1" to indicate that the
-- "hold" location should be ignored when creating the priority equipment sets
function inv.priority.locIsAllowed(wearableLoc, priorityName, level)

  if (wearableLoc == nil) or (wearableLoc == "") then
    dbot.warn("inv.priority.locIsAllowed: Missing wearable location parameter")
    return false
  end -- if

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.priority.locIsAllowed: Missing priority name parameter")
    return false
  end -- if

  level = tonumber(level or "")
  if (level == nil) or (level < 1) or (level > 291) then
    dbot.warn("inv.priority.locIsAllowed: Invalid level parameter")
    return false
  end -- if

  -- Check if the specified priority exists for the specified level
  local priorityTable, retval = inv.priority.get(priorityName, level)
  if (priorityTable == nil) then
    dbot.warn("inv.priority.locIsAllowed: Priority \"" .. priorityName ..
              "\" does not have a priority table " .. "for level " .. level)
    return false
  end -- if

  -- We can't use "~light" to specify a light location because that is used to indicate that
  -- we aren't using the light damage type.  Instead, we use "~lightEq" as a work-around in this
  -- situation to indicate the wearable light equipment location.
  local loc = wearableLoc
  if (wearableLoc == "light") then
    loc = "lighteq"
  end -- if

  -- Check if the priority has a non-zero entry for ~[some wearable location] telling us to ignore it
  local value = tonumber(priorityTable["~" .. loc] or "") or 0
  if (value == 0) then
    return true
  else
    return false
  end -- if

end -- inv.priority.locIsAllowed


function inv.priority.addDefault()
  local retval

  ----------------
  -- Priority: psi
  ----------------
  --[[ Here are the default statistic weightings from the Aardwolf scoring system for a
       primary psi.  This is what we will model in the "psi" priority.  Keep in mind that
       the plugin provides *many* more options to adjust your scoring and the aardwolf
       defaults are very simple.  Look at the "psi-melee" priority for an example of what
       you can do.  The table below was taken by running the "compare set" command on the
       Aardwolf mud using a primary psi character.  Hopefully it isn't copyrighted... :)

                                 Default   Your  
       Affect Bonus      Keyword Score     Score  
       ----------------- ------- -------  -------
       Strength          str          10       10
       Intelligence      int          15       15
       Wisdom            wis          15       15
       Dexterity         dex          10       10
       Constitution      con          10       10
       Luck              lck          12       12
       ------------------------------------------
       Hit points        hp            0        0
       Mana              mana          0        0
       Moves             moves         0        0
       ------------------------------------------
       Hit roll          hr            5        5
       Damage roll       dr            5        5
       Saves             save          0        0
       Resists           resist        0        0
       ------------------------------------------
       Damage            dam           4        4
       ------------------------------------------
  --]]
  retval = inv.priority.add(
    "psi", -- Equipment priorities using the default psi weightings from the aardwolf scoring system
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { 
                       str        = 1.0,  
                       int        = 1.5,
                       wis        = 1.5,
                       dex        = 1.0, 
                       con        = 1.0,  
                       luck       = 1.2,  
                       hit        = 0.5,  
                       dam        = 0.5,
                       avedam     = 0.4,
                       offhandDam = 0.4,
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"psi\": " .. dbot.retval.getString(retval))
  end -- if

  --------------------
  -- Priority: warrior
  --------------------
  --[[ Here are the default statistic weightings from the Aardwolf scoring system for a
       primary warrior.  This is what we will model in the "warrior" priority.

                                 Default   Your  
       Affect Bonus      Keyword Score     Score  
       ----------------- ------- -------  -------
       Strength          str          15       15
       Intelligence      int          10       10
       Wisdom            wis          10       10
       Dexterity         dex          15       15
       Constitution      con          10       10
       Luck              lck          10       10
       ------------------------------------------
       Hit points        hp            0        0
       Mana              mana          0        0
       Moves             moves         0        0
       ------------------------------------------
       Hit roll          hr            5        5
       Damage roll       dr            5        5
       Saves             save          0        0
       Resists           resist        0        0
       ------------------------------------------
       Damage            dam           4        4
       ------------------------------------------
  --]]
  retval = inv.priority.add(
    "warrior", -- Equipment priorities using the default warrior weightings from the aardwolf scoring system
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { 
                       str        = 1.5,  
                       int        = 1.0,
                       wis        = 1.0,
                       dex        = 1.5, 
                       con        = 1.0,  
                       luck       = 1.0,  
                       hit        = 0.5,  
                       dam        = 0.5,
                       avedam     = 0.4,
                       offhandDam = 0.4,
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"warrior\": " ..
              dbot.retval.getString(retval))
  end -- if

  -----------------
  -- Priority: mage
  -----------------
  --[[ Here are the default statistic weightings from the Aardwolf scoring system for a
       primary mage.  This is what we will model in the "mage" priority.

                                 Default   Your  
       Affect Bonus      Keyword Score     Score  
       ----------------- ------- -------  -------
       Strength          str          10       10
       Intelligence      int          15       15
       Wisdom            wis          10       10
       Dexterity         dex          10       10
       Constitution      con          10       10
       Luck              lck          10       10
       ------------------------------------------
       Hit points        hp            0        0
       Mana              mana          0        0
       Moves             moves         0        0
       ------------------------------------------
       Hit roll          hr            5        5
       Damage roll       dr            5        5
       Saves             save          0        0
       Resists           resist        0        0
       ------------------------------------------
       Damage            dam           4        4
       ------------------------------------------
  --]]
  retval = inv.priority.add(
    "mage", -- Equipment priorities using the default mage weightings from the aardwolf scoring system
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { 
                       str        = 1.0,  
                       int        = 1.5,
                       wis        = 1.0,
                       dex        = 1.0, 
                       con        = 1.0,  
                       luck       = 1.0,  
                       hit        = 0.5,  
                       dam        = 0.5,
                       avedam     = 0.4,
                       offhandDam = 0.4,
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"mage\": " .. dbot.retval.getString(retval))
  end -- if

  ------------------
  -- Priority: thief
  ------------------
  --[[ Here are the default statistic weightings from the Aardwolf scoring system for a
       primary thief.  This is what we will model in the "thief" priority.

                                 Default   Your  
       Affect Bonus      Keyword Score     Score  
       ----------------- ------- -------  -------
       Strength          str          12       12
       Intelligence      int          10       10
       Wisdom            wis          10       10
       Dexterity         dex          15       15
       Constitution      con          10       10
       Luck              lck          10       10
       ------------------------------------------
       Hit points        hp            0        0
       Mana              mana          0        0
       Moves             moves         0        0
       ------------------------------------------
       Hit roll          hr            5        5
       Damage roll       dr            5        5
       Saves             save          0        0
       Resists           resist        0        0
       ------------------------------------------
       Damage            dam           4        4
       ------------------------------------------
  --]]
  retval = inv.priority.add(
    "thief", -- Equipment priorities using the default thief weightings from the aardwolf scoring system
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { 
                       str        = 1.2,  
                       int        = 1.0,
                       wis        = 1.0,
                       dex        = 1.5, 
                       con        = 1.0,  
                       luck       = 1.0,  
                       hit        = 0.5,  
                       dam        = 0.5,
                       avedam     = 0.4,
                       offhandDam = 0.4,
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"thief\": " ..
              dbot.retval.getString(retval))
  end -- if

  -------------------
  -- Priority: ranger
  -------------------
  --[[ Here are the default statistic weightings from the Aardwolf scoring system for a
       primary ranger.  This is what we will model in the "ranger" priority.

                                 Default   Your  
       Affect Bonus      Keyword Score     Score  
       ----------------- ------- -------  -------
       Strength          str          10       10
       Intelligence      int          10       10
       Wisdom            wis          15       15
       Dexterity         dex          10       10
       Constitution      con          15       15
       Luck              lck          10       10
       ------------------------------------------
       Hit points        hp            0        0
       Mana              mana          0        0
       Moves             moves         0        0
       ------------------------------------------
       Hit roll          hr            5        5
       Damage roll       dr            5        5
       Saves             save          0        0
       Resists           resist        0        0
       ------------------------------------------
       Damage            dam           4        4
       ------------------------------------------
  --]]
  retval = inv.priority.add(
    "ranger", -- Equipment priorities using the default ranger weightings from the aardwolf scoring system
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { 
                       str        = 1.0,  
                       int        = 1.0,
                       wis        = 1.5,
                       dex        = 1.0, 
                       con        = 1.5,  
                       luck       = 1.0,  
                       hit        = 0.5,  
                       dam        = 0.5,
                       avedam     = 0.4,
                       offhandDam = 0.4,
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"ranger\": " ..
              dbot.retval.getString(retval))
  end -- if

  --------------------
  -- Priority: paladin
  --------------------
  --[[ Here are the default statistic weightings from the Aardwolf scoring system for a
       primary paladin.  This is what we will model in the "paladin" priority.

                                 Default   Your  
       Affect Bonus      Keyword Score     Score  
       ----------------- ------- -------  -------
       Strength          str          10       10
       Intelligence      int          15       15
       Wisdom            wis          10       10
       Dexterity         dex          10       10
       Constitution      con          15       15
       Luck              lck          10       10
       ------------------------------------------
       Hit points        hp            0        0
       Mana              mana          0        0
       Moves             moves         0        0
       ------------------------------------------
       Hit roll          hr            5        5
       Damage roll       dr            5        5
       Saves             save          0        0
       Resists           resist        0        0
       ------------------------------------------
       Damage            dam           4        4
       ------------------------------------------
  --]]
  retval = inv.priority.add(
    "paladin", -- Equipment priorities using the default paladin weightings from the aardwolf scoring system
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { 
                       str        = 1.0,  
                       int        = 1.5,
                       wis        = 1.0,
                       dex        = 1.0, 
                       con        = 1.5,  
                       luck       = 1.0,  
                       hit        = 0.5,  
                       dam        = 0.5,
                       avedam     = 0.4,
                       offhandDam = 0.4,
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"paladin\": " .. dbot.retval.getString(retval))
  end -- if

  -------------------
  -- Priority: cleric
  -------------------
  --[[ Here are the default statistic weightings from the Aardwolf scoring system for a
       primary cleric.  This is what we will model in the "cleric" priority.

                                 Default   Your  
       Affect Bonus      Keyword Score     Score  
       ----------------- ------- -------  -------
       Strength          str          10       10
       Intelligence      int          10       10
       Wisdom            wis          15       15
       Dexterity         dex          10       10
       Constitution      con          10       10
       Luck              lck          10       10
       ------------------------------------------
       Hit points        hp            0        0
       Mana              mana          0        0
       Moves             moves         0        0
       ------------------------------------------
       Hit roll          hr            5        5
       Damage roll       dr            5        5
       Saves             save          0        0
       Resists           resist        0        0
       ------------------------------------------
       Damage            dam           4        4
       ------------------------------------------
  --]]
  retval = inv.priority.add(
    "cleric", -- Equipment priorities using the default cleric weightings from the aardwolf scoring system
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { 
                       str        = 1.0,  
                       int        = 1.0,
                       wis        = 1.5,
                       dex        = 1.0, 
                       con        = 1.0,  
                       luck       = 1.0,  
                       hit        = 0.5,  
                       dam        = 0.5,
                       avedam     = 0.4,
                       offhandDam = 0.4,
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"cleric\": " ..
              dbot.retval.getString(retval))
  end -- if

  ----------------------
  -- Priority: psi-melee
  ----------------------
  -- This is designed for a psi with at least one melee class.  It fits my playing style well, but
  -- feel free to tweak it for your own use :)  Many additional options are available to tweak this
  -- even further.  See "dinv help priority" for more details.
  retval = inv.priority.add(
  "psi-melee", 
  { 
    { -- Priorities for levels 1 - 50
      minLevel = 1, 
      maxLevel = 50,
      priorities = {
                     str          = 1,  
                     int          = 0.6,
                     wis          = 0.6,
                     dex          = 0.8, 
                     con          = 0.2,  
                     luck         = 1, 
                     dam          = 0.9,
                     hit          = 0.4,

                     avedam       = 0.9,
                     offhandDam   = 0.3, 

                     hp           = 0.02,
                     mana         = 0.01,
                     moves        = 0,

                     sanctuary    = 50,
                     haste        = 20,
                     flying       = 5,
                     invis        = 10,
                     regeneration = 5, 
                     detectinvis  = 4,
                     detecthidden = 3,
                     detectevil   = 2,
                     detectgood   = 2,
                     dualwield    = 20,
                     irongrip     = 2,
                     shield       = 5,
                     hammerswing  = 0,

                     allmagic     = 0.03,
                     allphys      = 0.03
                   }
    },

    { -- Priorities for levels 51 - 100
      minLevel = 51, 
      maxLevel = 100, 
      priorities = {
                     str          = 0.9,  
                     int          = 0.8,
                     wis          = 0.8,
                     dex          = 0.7, 
                     con          = 0.3,  
                     luck         = 1, 
                     dam          = 0.9,
                     hit          = 0.5,

                     avedam       = 0.9,
                     offhandDam   = 0.4, 

                     hp           = 0.01,
                     mana         = 0.01,
                     moves        = 0,

                     sanctuary    = 10,
                     haste        = 5,
                     flying       = 4,
                     invis        = 5,
                     regeneration = 5, 
                     detectinvis  = 4,
                     detecthidden = 3,
                     detectevil   = 2,
                     detectgood   = 2,
                     dualwield    = 0,
                     irongrip     = 3,
                     shield       = 5,
                     hammerswing  = 0,

                     maxstr       = 0,
                     maxint       = 0,
                     maxwis       = 0,
                     maxdex       = 0,
                     maxcon       = 0,
                     maxluck      = 0,

                     allmagic     = 0.03,
                     allphys      = 0.05
                   }
    },

    { -- Priorities for levels 101 - 130
      minLevel = 101, 
      maxLevel = 130, 
      priorities = {
                     str          = 0.8,  
                     int          = 1.0,
                     wis          = 0.9,
                     dex          = 0.7, 
                     con          = 0.4,  
                     luck         = 1.0, 
                     dam          = 0.8,
                     hit          = 0.6,

                     avedam       = 0.8,
                     offhandDam   = 0.4, 

                     hp           = 0.01,
                     mana         = 0.01,
                     moves        = 0,

                     sanctuary    = 10,
                     haste        = 2,
                     flying       = 2,
                     invis        = 3,
                     regeneration = 5, 
                     detectinvis  = 2,
                     detecthidden = 2,
                     detectevil   = 2,
                     detectgood   = 2,
                     dualwield    = 0,
                     irongrip     = 20,
                     shield       = 10,
                     hammerswing  = 0,

                     allmagic     = 0.05,
                     allphys      = 0.10
                   }
    },

    { -- Priorities for levels 131 - 170
      minLevel = 131, 
      maxLevel = 170, 
      priorities = {
                     str          = 0.7,  
                     int          = 1.0,
                     wis          = 1.0,
                     dex          = 0.6, 
                     con          = 0.5,  
                     luck         = 1.0, 
                     dam          = 0.7,
                     hit          = 0.6,

                     avedam       = 0.7,
                     offhandDam   = 0.4, 

                     hp           = 0.01,
                     mana         = 0.01,
                     moves        = 0,

                     sanctuary    = 10,
                     haste        = 2,
                     flying       = 1,
                     invis        = 1,
                     regeneration = 5, 
                     detectinvis  = 2,
                     detecthidden = 2,
                     detectevil   = 2,
                     detectgood   = 2,
                     dualwield    = 0,
                     irongrip     = 20,
                     shield       = 20,
                     hammerswing  = 0,

                     allmagic     = 0.05,
                     allphys      = 0.10
                   }
    },

    { -- Priorities for levels 171 - 200
      minLevel = 171, 
      maxLevel = 200, 
      priorities = {
                     str          = 0.7,  
                     int          = 1.0,
                     wis          = 1.0,
                     dex          = 0.5, 
                     con          = 0.5,  
                     luck         = 1.0, 
                     dam          = 0.6,
                     hit          = 0.6,

                     avedam       = 0.6,
                     offhandDam   = 0.4, 

                     hp           = 0.01,
                     mana         = 0.01,
                     moves        = 0,

                     sanctuary    = 10,
                     haste        = 2,
                     flying       = 1,
                     invis        = 1,
                     regeneration = 5, 
                     detectinvis  = 2,
                     detecthidden = 2,
                     detectevil   = 2,
                     detectgood   = 2,
                     dualwield    = 0,
                     irongrip     = 25,
                     shield       = 25,
                     hammerswing  = 0,

                     maxint       = 10,
                     maxwis       = 10,
                     maxluck      = 5,

                     allmagic     = 0.05,
                     allphys      = 0.10
                   }
    },

    { -- Priorities for level 201 - 291
      minLevel = 201, 
      maxLevel = 291, 
      priorities = {
                     str          = 0.6,  
                     int          = 1.0,
                     wis          = 1.0,
                     dex          = 0.5, 
                     con          = 0.5,  
                     luck         = 1.0, 
                     dam          = 0.5,
                     hit          = 0.4,

                     avedam       = 0.5,
                     offhandDam   = 0.4, 

                     hp           = 0.01,
                     mana         = 0.01,
                     moves        = 0,

                     sanctuary    = 5,
                     haste        = 2,
                     flying       = 1,
                     invis        = 1,
                     regeneration = 2, 
                     detectinvis  = 2,
                     detecthidden = 2,
                     detectevil   = 2,
                     detectgood   = 2,
                     dualwield    = 0,
                     irongrip     = 30,
                     shield       = 30,
                     hammerswing  = 0,

                     maxint       = 40,
                     maxwis       = 40,
                     maxluck      = 20,

                     allmagic     = 0.05,
                     allphys      = 0.10
                   }
    }
  })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"psi-melee\": " ..
              dbot.retval.getString(retval))
  end -- if

  ------------------------
  -- Priority: psi-defense
  ------------------------
  -- This prioritizes defensive aspects of an equipment set
  local psiDefensePriority = {
                               str          = 0.6,  
                               int          = 1.0,
                               wis          = 1.0,
                               dex          = 0.8, 
                               con          = 0.8,  
                               luck         = 1.0, 
                               dam          = 0.5,
                               hit          = 0.5,

                               avedam       = 1.0,
                               offhandDam   = 0.0, 

                               hp           = 0.02,
                               mana         = 0.01,

                               sanctuary    = 10,
                               haste        = 0,
                               flying       = 0,
                               invis        = 1,
                               regeneration = 5, 
                               detectinvis  = 0,
                               detecthidden = 0,
                               detectevil   = 0,
                               detectgood   = 0,
                               dualwield    = 0,
                               irongrip     = 50,
                               shield       = 50,
                               hammerswing  = 0,

                               maxint       = 40,
                               maxwis       = 40,
                               maxluck      = 20,

                               allmagic     = 0.05,
                               allphys      = 0.10
                             }
  psiDefensePriority["~second"] = 1 -- Minor hack since the "~" messes up table keys
  retval = inv.priority.add(
    "psi-defense", 
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = psiDefensePriority
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"balance\": " ..
              dbot.retval.getString(retval))
  end -- if

  ------------------------
  -- Priority: psi-balance
  ------------------------
  -- This priority lowers wis as much as possible while boosting int.  This will give you the biggest
  -- possible bonus to wis when you cast mental balance.  You can then wear your normal equipment while
  -- retaining the wis bonus.
  retval = inv.priority.add(
    "psi-balance", -- Equipment priorities to maximize benefits from the mental balance spell
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { int = 1,
                       wis = -1
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"balance\": " ..
              dbot.retval.getString(retval))
  end -- if

  ----------------------
  -- Priority: enchanter
  ----------------------
  -- This refers to anyone enchanting, not just an enchanter sub-class.  It boosts the three
  -- stats responsible for improving enchantments.  You probably don't want to try leveling
  -- with a set based on this :)
  retval = inv.priority.add(
    "enchanter", -- Equipment priorities for an enchanter (only care about int, luck, wis)
    { 
      { -- Priorities for levels 1 - 291
        minLevel = 1, 
        maxLevel = 291, 
        priorities = { int  = 1,
                       luck = 1,
                       wis  = 1
                     }
      }
    })
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.priority.addDefault: Failed to add priority \"enchanter\": " ..
             dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.priority.addDefault


-- ordinal number, name, and description of each possible priority field
inv.priority.fieldTable = {

  { "str"         , "Value of 1 point of the strength stat" },
  { "int"         , "Value of 1 point of the intelligence stat" },
  { "wis"         , "Value of 1 point of the wisdom stat" },
  { "dex"         , "Value of 1 point of the dexterity stat" },
  { "con"         , "Value of 1 point of the constitution stat" },
  { "luck"        , "Value of 1 point of the luck stat" },

  { "dam"         , "Value of 1 point of damroll" },
  { "hit"         , "Value of 1 point of hitroll" },

  { "avedam"      , "Value of 1 point of primary weapon ave damage" },
  { "offhandDam"  , "Value of 1 point of offhand weapon ave damage" },

  { "hp"          , "Value of 1 hit point" },
  { "mana"        , "Value of 1 mana point" },
  { "moves"       , "Value of 1 movement point" },

  { "sanctuary"   , "Value placed on the sanctuary effect " },
  { "haste"       , "Value placed on the haste effect " },
  { "flying"      , "Value placed on the flying effect " },
  { "invis"       , "Value placed on the invisible effect " },
  { "regeneration", "Value placed on the regeneration effect" },
  { "detectinvis" , "Value placed on the detect invis effect " },
  { "detecthidden", "Value placed on the detect hidden effect " },
  { "detectevil"  , "Value placed on the detect evil effect " },
  { "detectgood"  , "Value placed on the detect good effect " },
  { "detectmagic" , "Value placed on the detect magic effect " },
  { "dualwield"   , "Value of an item's dual wield effect" },
  { "irongrip"    , "Value of an item's irongrip effect" },
  { "shield"      , "Value of a shield's damage reduction effect" },
  { "hammerswing" , "Value of a hammer weapon for the hammerswing skill" },
  { "metalweapon" , "Score bonus for weapons made of metal (e.g. for blacksmith priorities)." },

  { "maxstr"      , "Value of hitting a level's strength ceiling" },
  { "maxint"      , "Value of hitting a level's intelligence ceiling" },
  { "maxwis"      , "Value of hitting a level's wisdom ceiling" },
  { "maxdex"      , "Value of hitting a level's dexterity ceiling" },
  { "maxcon"      , "Value of hitting a level's constitution ceiling" },
  { "maxluck"     , "Value of hitting a level's luck ceiling" },

  { "allmagic"    , "Value of 1 point in each magical resist type" },
  { "allphys"     , "Value of 1 point in each physical resist type" },

  { "bash"        , "Value of 1 point of bash physical resistance" },
  { "pierce"      , "Value of 1 point of pierce physical resistance" },
  { "slash"       , "Value of 1 point of slash physical resistance" },

  { "acid"        , "Value of 1 point of acid magical resistance" },
  { "air"         , "Value of 1 point of air magical resistance" },
  { "cold"        , "Value of 1 point of cold magical resistance" },
  { "disease"     , "Value of 1 point of disease magical resistance" },
  { "earth"       , "Value of 1 point of earth magical resistance" },
  { "electric"    , "Value of 1 point of electric magical resistance" },
  { "energy"      , "Value of 1 point of energy magical resistance" },
  { "fire"        , "Value of 1 point of fire magical resistance" },
  { "holy"        , "Value of 1 point of holy magical resistance" },
  { "light"       , "Value of 1 point of light magical resistance" },
  { "magic"       , "Value of 1 point of magic magical resistance" },
  { "mental"      , "Value of 1 point of mental magical resistance" },
  { "negative"    , "Value of 1 point of negative magical resistance" },
  { "poison"      , "Value of 1 point of poison magical resistance" },
  { "shadow"      , "Value of 1 point of shadow magical resistance" },
  { "sonic"       , "Value of 1 point of sonic magical resistance" },
  { "water"       , "Value of 1 point of water magical resistance" },

-- Note: We use "~light" to ignore the light damType not to ignore the light wearable location
  { "~lightEq"    , "Set to 1 to disable the light location" },
  { "~head"       , "Set to 1 to disable the head location" },
  { "~eyes"       , "Set to 1 to disable the eyes location" },
  { "~lear"       , "Set to 1 to disable the left ear location" },
  { "~rear"       , "Set to 1 to disable the right ear location" },
  { "~neck1"      , "Set to 1 to disable the neck1 location" },
  { "~neck2"      , "Set to 1 to disable the neck2 location" },
  { "~back"       , "Set to 1 to disable the back location" },
  { "~medal1"     , "Set to 1 to disable the medal1 location" },
  { "~medal2"     , "Set to 1 to disable the medal2 location" },
  { "~medal3"     , "Set to 1 to disable the medal3 location" },
  { "~medal4"     , "Set to 1 to disable the medal4 location" },
  { "~torso"      , "Set to 1 to disable the torso location" },
  { "~body"       , "Set to 1 to disable the body location" },
  { "~waist"      , "Set to 1 to disable the waist location" },
  { "~arms"       , "Set to 1 to disable the arms location" },
  { "~lwrist"     , "Set to 1 to disable the left wrist location" },
  { "~rwrist"     , "Set to 1 to disable the right wrist location" },
  { "~hands"      , "Set to 1 to disable the hands location" },
  { "~lfinger"    , "Set to 1 to disable the left finger location" },
  { "~rfinger"    , "Set to 1 to disable the right finger location" },
  { "~legs"       , "Set to 1 to disable the legs location" },
  { "~feet"       , "Set to 1 to disable the feet location" },
  { "~shield"     , "Set to 1 to disable the shield location" },
  { "~wielded"    , "Set to 1 to disable the wielded location" },
  { "~second"     , "Set to 1 to disable the second location" },
  { "~hold"       , "Set to 1 to disable the hold location" },
  { "~float"      , "Set to 1 to disable the float location" },
  { "~above"      , "Set to 1 to disable the above location" },
  { "~portal"     , "Set to 1 to disable the portal location" },
  { "~sleeping"   , "Set to 1 to disable the sleeping location" },

  { "~bash"       , "Set to 1 to disable weapons with damtype bash" },
  { "~pierce"     , "Set to 1 to disable weapons with damtype pierce" },
  { "~slash"      , "Set to 1 to disable weapons with damtype slash" },

  { "~acid"       , "Set to 1 to disable weapons with damtype acid" },
  { "~air"        , "Set to 1 to disable weapons with damtype air" },
  { "~cold"       , "Set to 1 to disable weapons with damtype cold" },
  { "~disease"    , "Set to 1 to disable weapons with damtype disease" },
  { "~earth"      , "Set to 1 to disable weapons with damtype earth" },
  { "~electric"   , "Set to 1 to disable weapons with damtype electric" },
  { "~energy"     , "Set to 1 to disable weapons with damtype energy" },
  { "~fire"       , "Set to 1 to disable weapons with damtype fire" },
  { "~holy"       , "Set to 1 to disable weapons with damtype holy" },
  { "~light"      , "Set to 1 to disable weapons with damtype light" },
  { "~magic"      , "Set to 1 to disable weapons with damtype magic" },
  { "~mental"     , "Set to 1 to disable weapons with damtype mental" },
  { "~negative"   , "Set to 1 to disable weapons with damtype negative" },
  { "~poison"     , "Set to 1 to disable weapons with damtype poison" },
  { "~shadow"     , "Set to 1 to disable weapons with damtype shadow" },
  { "~sonic"      , "Set to 1 to disable weapons with damtype sonic" },
  { "~water"      , "Set to 1 to disable weapons with damtype water" }

}

-- Build the Lua↔SQL column mapping now that fieldTable is defined
inv.priority.buildColumnMap()



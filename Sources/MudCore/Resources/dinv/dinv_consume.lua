----------------------------------------------------------------------------------------------------
--
-- Module to manage buying and using consumables (potions, pills, scrolls, etc.)
--
-- dinv consume add     [type] [itemName]
--              remove  [type] <itemName>
--              display <type>
--              list
--              buy     [type] <numItems>
--              small   [type] <numItems>
--              big     [type] <numItems>
--
-- inv.consume.init.atActive()
-- inv.consume.fini(doSaveState)
--
-- inv.consume.save()
-- inv.consume.load()
-- inv.consume.reset()
--
-- inv.consume.add(typeName, itemName)
-- inv.consume.addCR() -- async so that we can appraise the new item
-- inv.consume.remove(typeName, itemName)
-- inv.consume.display(typeName) -- if typeName is missing, display all types
-- inv.consume.displayType(typeName, isOwned)
--
-- inv.consume.buy(typeName, numItems, containerName)
-- inv.consume.buyCR() -- async so that we can run to the shopkeeper
-- inv.consume.get(typeName, size, containerId)
-- inv.consume.use(typeName, size, numItems, containerName)
-- inv.consume.useCR()
-- inv.consume.useItem(objId, commandArray)
-- 
-- Consumable table format:
--   table[typeName] = 
--     { heal  = { { level=1,   name="light relief",   room="32476", fullName="(!(Light Relief)!)" },
--                 { level=20,  name="serious relief", room="32476", fullName="(!(Serious Relief)!)" } },
--       mana  = { { level=1,   name="lotus rush",     room="32476", fullName="(!(Lotus Rush)!)" } },
--       fly   = { { level=1,   name="griff",          room="32476", fullName="(!(Griffon's Blood)!)" } }
--     }
-- 
----------------------------------------------------------------------------------------------------

inv.consume           = {}
inv.consume.init      = {}
inv.consume.table     = {}


function inv.consume.init.atActive()
  local retval = DRL_RET_SUCCESS

  retval = inv.consume.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.consume.init.atActive: failed to load consume data from storage: " .. 
              dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.consume.init.atActive


function inv.consume.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  if (doSaveState) then
    -- Save our current data
    retval = inv.consume.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.consume.fini: Failed to save inv.consume module data: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- inv.consume.fini


function inv.consume.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  if not inv.consume.table then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM consumables")

    for typeName, items in pairs(inv.consume.table) do
      for _, item in ipairs(items) do
        local query = string.format(
          "INSERT INTO consumables (type_name, level, name, room, full_name) VALUES (%s, %s, %s, %s, %s)",
          dinv_db.fixsql(typeName),
          dinv_db.fixnum(item.level),
          dinv_db.fixsql(item.name),
          dinv_db.fixsql(item.room),
          dinv_db.fixsql(item.fullName))
        db:exec(query)
        if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
          dbot.warn("inv.consume.save: Failed to save consumable " .. (item.name or "?"))
          return DRL_RET_INTERNAL_ERROR
        end
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- inv.consume.save


function inv.consume.load()
  local db = dinv_db.handle
  if not db then
    inv.consume.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any consumable rows exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM consumables") do
    count = row.cnt
  end

  if count == 0 then
    inv.consume.reset()
    return DRL_RET_SUCCESS
  end

  -- Load consumables grouped by type_name
  inv.consume.table = {}
  for row in db:nrows("SELECT type_name, level, name, room, full_name FROM consumables ORDER BY id") do
    if not inv.consume.table[row.type_name] then
      inv.consume.table[row.type_name] = {}
    end
    table.insert(inv.consume.table[row.type_name], {
      level    = row.level,
      name     = row.name,
      room     = row.room,
      fullName = row.full_name,
    })
  end

  return DRL_RET_SUCCESS
end -- inv.consume.load


function inv.consume.reset()
  -- Start with a few basic consumables from the Aylor potion shop ("runto potion")
  inv.consume.table =
    { heal  = { { level=1,   name="light relief",   room="32476", fullName="(!(Light Relief)!)" },
                { level=20,  name="serious relief", room="32476", fullName="(!(Serious Relief)!)" } },
      mana  = { { level=1,   name="lotus rush",     room="32476", fullName="(!(Lotus Rush)!)" } },
      fly   = { { level=1,   name="griff",          room="32476", fullName="(!(Griffon's Blood)!)" } }
    }

  local retval = inv.consume.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.consume.reset: Failed to save consumable data: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.consume.reset


inv.consume.addPkg = nil
function inv.consume.add(typeName, itemName)
  if (typeName == nil) or (typeName == "") then
    dbot.warn("inv.consume.add: Missing type name")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (itemName == nil) or (itemName == "") then
    dbot.warn("inv.consume.add: Missing item name")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (inv.consume.addPkg ~= nil) then
    dbot.info("Skipping request to add a consumable item: another request is in progress")
    return DRL_RET_BUSY
  end -- if

  inv.consume.addPkg       = {}
  inv.consume.addPkg.type  = typeName
  inv.consume.addPkg.name  = itemName
  inv.consume.addPkg.level = nil  -- resolved during addCR from identified item
  inv.consume.addPkg.room  = nil  -- resolved during addCR from current room

  wait.make(inv.consume.addCR)

  return DRL_RET_SUCCESS

end -- inv.consume.add


function inv.consume.addCR()
  local retval = DRL_RET_SUCCESS
  local typeName = inv.consume.addPkg.type
  local itemName = inv.consume.addPkg.name or ""
  local itemLevel = inv.consume.addPkg.level

  -- We don't want an inventory refresh triggering in the middle of this shop item evaluation.
  local origRefreshState = inv.state
  if (inv.state == invStateIdle) then
    inv.state = invStatePaused
  elseif (inv.state == invStateRunning) then
    dbot.info("Skipping shop item addition: you are in the middle of an inventory refresh")
    inv.consume.addPkg = nil
    return DRL_RET_BUSY
  end -- if

  -- If the optional room ID is not present, use the current room
  local roomId = tonumber(inv.consume.addPkg.room or "")
  if (roomId == nil) then
    roomId = dbot.gmcp.getRoomId() or 0
  end -- if

  if (inv.consume.table[typeName] == nil) then
    inv.consume.table[typeName] = {}
  end -- if

  -- Temporarily create an item placeholder with a fake object ID and a fake location.
  -- We will fill in this placeholder with information from a shopkeeper appraisal later.
  -- Use a negative ID to avoid collision with real item IDs (always positive from the MUD).
  local objId = -1
  retval = inv.items.add(objId)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.consume.addCR: Failed to add fake objId " .. (objId or "nil") .. ": " ..
              dbot.retval.getString(retval))
    inv.consume.addPkg = nil
    inv.state = origRefreshState
    return retval
  end -- if

  -- Fake a location for the shop item
  inv.items.setField(objId, invFieldObjLoc, invItemLocShopkeeper)

  -- Attempt to identify the shopkeeper item and wait until we have confirmation that the ID completed
  local resultData = dbot.callback.new()
  retval = inv.items.identifyItem(objId, "appraise " .. itemName, resultData)
  if (retval == DRL_RET_SUCCESS) then
    retval = dbot.callback.wait(resultData, inv.items.timer.idTimeoutThresholdSec)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.consume.addCR: Appraisal timed out for shopkeeper item " ..
                (inv.consume.addPkg.name or "unknown"))
    end -- if
  end -- if

  -- Get the level of the shop item we just identified
  itemLevel = tonumber(inv.items.getStatField(objId, invStatFieldLevel) or "")
  local fullName = inv.items.getStatField(objId, invStatFieldName) or ""

  -- We keep consumable items in the frequent cache so we may as well add it now so that
  -- we don't slow things down later when we buy the consumable item
  inv.cache.add(inv.cache.frequent.table, objId)

  -- Remove the temporary item and ensure it isn't stuck in the recent cache
  inv.items.remove(objId)
  inv.cache.remove(inv.cache.recent.table, objId)

  if (itemLevel ~= nil) then

    -- If the item is already in the table, don't add it again!
    local itemExists = false
    for i, entry in ipairs(inv.consume.table[typeName]) do
      if (entry.level == itemLevel) and (entry.name == itemName) then
        dbot.note("Skipping addition of consumable item \"" .. itemName .. "\" of type \"" .. 
                  typeName .. "\": item already exists")
        itemExists = true
        break
      end -- if
    end -- for

    -- If the item isn't already in the consumable table, add it and then re-sort the table to
    -- account for the new item
    if (itemExists == false) then
      table.insert(inv.consume.table[typeName],
                  { level = itemLevel, name = itemName, room = roomId, fullName = fullName })
      table.sort(inv.consume.table[typeName], function (v1, v2) return v1.level < v2.level end)
      inv.consume.save()
      dbot.info("Added \"@G" .. itemName .. "@W\" (Level " .. (itemLevel or "?") ..
                ") to " .. typeName .. " consumables")
    end -- if
  else
    dbot.warn("inv.consume.addCR: Failed to identify shop item \"" .. itemName .. "\" in room \"" .. roomId)
    retval = DRL_RET_MISSING_ENTRY
  end -- if

  -- Restore the original refresh state (we may have paused it during this operation)
  inv.state = origRefreshState

  -- Clean up and return
  inv.consume.addPkg = nil
  return retval
end -- inv.consume.addCR


function inv.consume.remove(typeName, itemName)
  if (typeName == nil) or (typeName == "") then
    dbot.warn("inv.consume.remove: Missing type name")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (inv.consume.table == nil) or (inv.consume.table[typeName] == nil) then
    dbot.info("Type \"" .. typeName .. "\" is not in the consumable table")
    return DRL_RET_MISSING_ENTRY
  end -- if

  local retval = DRL_RET_MISSING_ENTRY

  -- If itemName is nil, remove all of the specified type
  if (itemName == nil) or (itemName == "") then
    dbot.note("Removed all \"" .. typeName .. "\" consumables from consumable table")
    inv.consume.table[typeName] = nil
    inv.consume.save()
    retval = DRL_RET_SUCCESS

  -- Search the table for the item matching "itemName" and remove just that item
  else
    for i, entry in ipairs(inv.consume.table[typeName]) do
      if (entry.name == itemName) then
        dbot.note("Removed \"" .. itemName .. "\" from \"" .. typeName .. "\" consumable table")
        table.remove(inv.consume.table[typeName], i)
        inv.consume.save()
        retval = DRL_RET_SUCCESS
        break
      end -- if
    end -- for
  end -- if

  if (retval == DRL_RET_MISSING_ENTRY) then
    dbot.info("Skipping removal of consumable \"" .. itemName .. "\": item is not in consumable table")
  end -- if

  return retval
end -- inv.consume.remove


-- If typeName is nil or "", display all types in the table
function inv.consume.display(typeName)
  local retval = DRL_RET_SUCCESS
  local numEntries = 0

  local isOwned = false
  if (typeName == "owned") then
    isOwned = true
  end -- if

  if (typeName ~= nil) and (typeName ~= "") and (not isOwned) then
    numEntries = inv.consume.displayType(typeName)
  else
    local sortedTypes = {}
    for itemType,_ in pairs(inv.consume.table) do
      table.insert(sortedTypes, itemType)
    end -- for
    table.sort(sortedTypes, function (v1, v2) return v1 < v2 end)

    for _, itemType in ipairs(sortedTypes) do
      numEntries = numEntries + inv.consume.displayType(itemType, isOwned)
    end -- for
  end -- if

  if (numEntries == 0) then
    dbot.print("@W  No items of type \"" .. typeName .. "\" are in the consumable table@w")
    retval = DRL_RET_MISSING_ENTRY
  end -- if

  return retval
end -- inv.consume.display


function inv.consume.displayType(typeName, isOwned)
  local numEntries = 0

  if (inv.consume.table == nil) or (typeName == nil) or (typeName == "") or 
     (inv.consume.table[typeName] == nil) then
    dbot.warn("inv.consume.displayType: Type \"" .. (typeName or "nil") .. 
              "\" is not in the consumable table")
    return numEntries, DRL_RET_MISSING_ENTRY
  end -- if

  local header = string.format("\n@W@C%-10s@W Level   Room  # Avail  Name", (typeName or "nil"))
  local hasOutOfStock = false
  local didPrintHeader = false

  if (inv.consume.table[typeName] ~= nil) then
    for _, entry in ipairs(inv.consume.table[typeName]) do
      local count = 0

      -- Use SQL to count matching items instead of iterating the entire inventory
      local db = dinv_db.handle
      if db and entry.level and entry.fullName then
        local query = string.format(
          "SELECT COUNT(*) as cnt FROM items WHERE level = %s AND name = %s AND (keywords IS NULL OR keywords NOT LIKE '%%dinvIgnore%%')",
          dinv_db.fixnum(entry.level), dinv_db.fixsql(entry.fullName))
        for row in db:nrows(query) do
          count = row.cnt
        end
      end

      local countColor = ""
      if (count > 0) then
        countColor = "@M" 
      end -- if

      if (isOwned == nil) or (isOwned == false) or (isOwned and (count > 0)) then
        if (not didPrintHeader) then
          dbot.print(header)
          didPrintHeader = true
        end -- if
        dbot.print(string.format("             %3d  %5d     %s%4d@w  %s",
                   (entry.level or 0), (entry.room or 0), countColor, count, (entry.name or "nil")))
      end -- if
      if (count == 0) then hasOutOfStock = true end
      numEntries = numEntries + 1
    end -- for
  end -- if

  if hasOutOfStock and didPrintHeader then
    dbot.print("@w  Tip: \"@G" .. pluginNameCmd .. " consume buy " .. typeName ..
               " <quantity>@w\" to restock")
  end

  return numEntries, DRL_RET_SUCCESS
end -- inv.consume.displayType


inv.consume.buyPkg = nil
function inv.consume.buy(typeName, numItems, containerName)
  if (typeName == nil) or (typeName == "") then
    dbot.warn("inv.consume.buy: Missing type name")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- If the user didn't specify how many items to buy, default to 1 item
  numItems = tonumber(numItems or "")
  if (numItems == nil) then
    numItems = 1
  end -- if

  -- If there are no entries of the specified type, there's no need to keep searching
  if (inv.consume.table[typeName] == nil) then
    dbot.info("No items of type \"" .. typeName .. "\" are in the consumable table")
    return DRL_RET_MISSING_ENTRY
  end -- if

  -- The containerName parameter is optional.  If it is present, we move the bought items
  -- into the container after the purchase is complete.
  containerName = containerName or ""

  -- Find the highest level item that is available to the char that matches typeName
  local curLevel = dbot.gmcp.getLevel()
  local bestEntry = nil
  for _, entry in ipairs(inv.consume.table[typeName]) do
    if (entry.level <= curLevel) then
      bestEntry = entry
    end -- if
  end -- for

  if (bestEntry == nil) then
    dbot.info("No items of type \"" .. typeName .. "\" are available at level " .. curLevel)
    return DRL_RET_MISSING_ENTRY
  end -- if

  dbot.info("Buying " .. numItems .. "x \"@G" .. bestEntry.name .. "@W\" (Level " ..
            bestEntry.level .. ") from room " .. bestEntry.room)

  if (inv.consume.buyPkg ~= nil) then
    dbot.info("Skipping request to buy consumable \"" .. typeName .. "\": another request is in progress")
    return DRL_RET_BUSY
  end -- if

  inv.consume.buyPkg               = {}
  inv.consume.buyPkg.room          = bestEntry.room
  inv.consume.buyPkg.itemName      = bestEntry.name
  inv.consume.buyPkg.numItems      = numItems
  inv.consume.buyPkg.containerName = containerName

  wait.make(inv.consume.buyCR)

  return DRL_RET_SUCCESS
end -- inv.consume.buy


-- need to block so that we can run to the shopkeeper
function inv.consume.buyCR() 
  local retval = DRL_RET_SUCCESS
  local room = tonumber(inv.consume.buyPkg.room or "")

  if (room == nil) then
    dbot.warn("inv.consume.buyCR: Target room is missing")
    inv.consume.buyPkg = nil
    return DRL_RET_INVALID_PARAM
  end -- if

  dbot.debug("Running to \"" .. inv.consume.buyPkg.room .. "\" to buy \"" .. inv.consume.buyPkg.numItems ..
             "\" of \"" .. inv.consume.buyPkg.itemName .. "\"")

  -- Run!
  dbot.info("Running to room " .. inv.consume.buyPkg.room .. "...")
  dbot.execute.fast.command("mapper goto " .. inv.consume.buyPkg.room)

  -- Wait until we get to the target room
  local totTime = 0
  local timeout = 10
  while (room ~= tonumber(dbot.gmcp.getRoomId())) do
    wait.time(drlSpinnerPeriodDefault)
    totTime = totTime + drlSpinnerPeriodDefault
    if (totTime > timeout) then
      dbot.warn("inv.consume.buyCR: Timed out running to room " .. room)
      retval = DRL_RET_TIMEOUT
      break
    end -- if
  end -- if 

  -- Buy the items if no problems came up going to the room
  if (retval == DRL_RET_SUCCESS) then
    local commands = {}
    table.insert(commands, "buy " .. inv.consume.buyPkg.numItems .. " " .. inv.consume.buyPkg.itemName)

    -- Use explicit container if provided, otherwise fall back to auto-organize config
    local targetContainer = inv.consume.buyPkg.containerName or ""
    if (targetContainer == "") then
      targetContainer = inv.config.table.consumeBuyContainer or ""
    end -- if

    if (targetContainer ~= "") then
      table.insert(commands,
                   "put all.\'" .. inv.consume.buyPkg.itemName .. "\' " .. targetContainer)
    end -- if

    dbot.execute.fast.commands(commands)
    dbot.info("Purchase command sent for " .. inv.consume.buyPkg.numItems ..
              "x \"@G" .. inv.consume.buyPkg.itemName .. "@W\"")
  end -- if

  -- Clean up and return
  inv.consume.buyPkg = nil
  return retval
end -- inv.consume.buyCR


-- Returns objId for an item 
function inv.consume.get(typeName, size, containerId)
  local curLevel = dbot.gmcp.getLevel()

  if (typeName == nil) or (typeName == "") then
    dbot.warn("inv.consume.get: type name is missing")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (inv.consume.table[typeName] == nil) then
    dbot.warn("inv.consume.get: no consumables of type \"" .. typeName .. "\" are available")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- If the user specified a preferred container, use items from that container first.  If they
  -- didn't specify a preferred container, use items from the main inventory first before using
  -- items from other locations.
  local preferredLocation
  containerId = tonumber(containerId or "")
  if (containerId ~= nil) then
    preferredLocation = containerId
  else
    preferredLocation = invItemLocInventory
  end -- if

  -- If we are getting a "small" item, keep the default table order of small-to-big so that we
  -- hit small items first.  If we are getting a "big" item, get a copy of the table (so we don't
  -- mess up the original) and then sort the copy in reverse order with high-level items first.
  local typeTable
  if (size == drlConsumeBig) then
    typeTable = dbot.table.getCopy(inv.consume.table[typeName])
    table.sort(typeTable, function (v1, v2) return v1.level > v2.level end)
  elseif (size == drlConsumeSmall) then
    typeTable = inv.consume.table[typeName]
  else
    dbot.warn("inv.consume.get: invalid size parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  for _, entry in pairs(typeTable) do
    if (entry.level <= curLevel) then
      -- If we have one of these items available, return the ID for it.  Otherwise, try the next entry
      -- in the consumable table
      local finalId = nil
      local preferredId = nil
      local count = 0

      for objId, itemEntry in pairs(inv.items.table) do
        local itemLevel = tonumber(inv.items.getStatField(objId, invStatFieldLevel) or "")
        local itemName  = inv.items.getStatField(objId, invStatFieldName) or ""

        if (entry.level == itemLevel) and (entry.fullName == itemName) and
           (not inv.items.isIgnored(objId)) then
          count = count + 1

          -- We try to use items from the preferred location first (e.g., a user-specified container or
          -- the main inventory if no container is specified).  If we find an item instance at the
          -- preferred location, break immediately and use it.  Otherwise, remember the item and keep
          -- searching for something at the preferred location.
          if (preferredId == nil) and (inv.items.getField(objId, invFieldObjLoc) == preferredLocation) then
            preferredId = objId
          else
            finalId = objId
          end -- if
        end -- if
      end -- for

      if (preferredId ~= nil) then
        finalId = preferredId
      end -- if

      local countColor
      if (count > 50) then
        countColor = "@G"
      elseif (count > 20) then
        countColor = "@Y"
      else
        countColor = "@R"
      end -- if

      -- If we found a matching item instance, return it!
      if (finalId ~= nil) then
        dbot.info("(" .. countColor .. count .. " available@W) " ..
                  "Consuming L" .. entry.level .. " \"@C" .. typeName .. "@W\" @Y" ..
                  (inv.items.getStatField(finalId, invStatFieldName) or "") .. "@W")


        return finalId, DRL_RET_SUCCESS
      end -- if

    end -- if
  end -- for

  return 0, DRL_RET_MISSING_ENTRY
end -- inv.consume.get


drlConsumeBig   = "big"
drlConsumeSmall = "small"
inv.consume.usePkg = nil
function inv.consume.use(typeName, size, numItems, containerName)
  if (typeName == nil) or (typeName == "") then
    dbot.warn("inv.consume.use: Missing type name")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- If the number of items isn't specified, use a single item as the default
  numItems = tonumber(numItems or "")
  if (numItems == nil) then
    numItems = 1
  end -- if

  if (numItems > drlConsumeMaxConsecutiveItems) then
    dbot.info("Capping consumption to " .. drlConsumeMaxConsecutiveItems ..
              " items (requested " .. numItems .. ")")
    numItems = drlConsumeMaxConsecutiveItems
  end -- if

  if (inv.consume.usePkg ~= nil) then
    dbot.info("Skipping request to use \"" .. typeName .. "\": another request is in progress")
    return DRL_RET_BUSY
  end -- if

  if (size ~= drlConsumeBig) and (size ~= drlConsumeSmall) then
    dbot.warn("inv.consume.use: size must be either \"" .. drlConsumeBig .. "\" or \"" .. 
              drlConsumeSmall .. "\"")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- The containerName parameter is optional.  If it is present, we use items from the 
  -- specified container before we items outside of that container.
  containerName = containerName or ""

  inv.consume.usePkg           = {}
  inv.consume.usePkg.numItems  = numItems
  inv.consume.usePkg.typeName  = typeName
  inv.consume.usePkg.size      = size
  inv.consume.usePkg.container = containerName

  wait.make(inv.consume.useCR)

  return DRL_RET_SUCCESS
end -- inv.consume.use

drlConsumeMaxConsecutiveItems = 10
function inv.consume.useCR()
  local retval = DRL_RET_SUCCESS
  local objId

  if (inv.consume.usePkg == nil) or (inv.consume.usePkg.size == nil) or 
     (inv.consume.usePkg.numItems == nil) or (inv.consume.usePkg.typeName == nil) then
    dbot.error("inv.consume.useCR: usePkg is nil or contains nil components")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  if (inv.consume.usePkg.numItems > drlConsumeMaxConsecutiveItems) then
    dbot.note("Capping number of \"" .. inv.consume.usePkg.size .. "\" items to consume to " ..
              drlConsumeMaxConsecutiveItems .. " in one burst")
    inv.consume.usePkg.numItems = drlConsumeMaxConsecutiveItems
  end -- if

  -- If the user specified a preferred container, use items from that container first
  local containerId = nil
  if (inv.consume.usePkg.container ~= nil) and (inv.consume.usePkg.container ~= "") then
    local idArray, retval = inv.items.searchCR("rname " .. inv.consume.usePkg.container)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.consume.useCR: failed to search inventory table: " .. dbot.retval.getString(retval))
    elseif (#idArray ~= 1) then
      -- There should only be a single match to the container's relative name (e.g., "2.bag")
      dbot.warn("Container relative name \"" .. inv.consume.usePkg.container .. 
                "\" did not have a unique match: no preferred container will be used for consume request")
    else
      -- We found a single unique match for the relative name
      containerId = idArray[1]
    end -- if
  end -- if

  local commandArray = {}
  local numConsumed = 0
  for i = 1, inv.consume.usePkg.numItems do
    objId, retval = inv.consume.get(inv.consume.usePkg.typeName, inv.consume.usePkg.size, containerId)
    if (objId ~= nil) and (retval == DRL_RET_SUCCESS) then
      retval = inv.consume.useItem(objId, commandArray)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.consume.useCR: Failed to consume item: " .. dbot.retval.getString(retval))
        break
      end -- if
      numConsumed = numConsumed + 1
    end -- if

    if (retval ~= DRL_RET_SUCCESS) then
      break;
    end -- if
  end -- for

  -- We use the "fast" mode instead of "safe" mode because we don't want the extra overhead when
  -- consuming items.  There's a good chance that you are in combat and stalling combat isn't a
  -- great idea.  The worst case scenario is that the user goes AFK or something silly in the
  -- middle of consuming the items and we try to consume them anyway.  It's not a huge issue.
  if (commandArray ~= nil) then
    if (#commandArray > 0) then
      retval = dbot.execute.fast.commands(commandArray)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.note("Skipping request to consume items: " .. dbot.retval.getString(retval))
      end -- if
    else
      dbot.note("Skipping request to consume items: no items matching the request were found")
    end -- if
  end -- if

  if (numConsumed > 0) then
    dbot.info("Consumed " .. numConsumed .. "x " .. inv.consume.usePkg.typeName)
  end

  -- Clean up
  inv.consume.usePkg = nil
  return retval
end -- inv.consume.useCR


function inv.consume.useItem(objId, commandArray)
  local retval = DRL_RET_SUCCESS
  local itemType = inv.items.getStatField(objId, invStatFieldType) or ""
  local consumeCmd

  if (itemType == "Potion") then
    consumeCmd = "quaff"
  elseif (itemType == "Pill") or (itemType == "Food") then
    consumeCmd = "eat"
  elseif (itemType == "Scroll") then
    consumeCmd = "recite"
  elseif (itemType == "Staff") or (itemType == "Wand") then
    consumeCmd = "hold"
  else
    dbot.warn("inv.consume.useItem: Unsupported item type \"" .. itemType .. "\"")
    return DRL_RET_UNSUPPORTED
  end -- if  

  -- If the item isn't already in the main inventory, get it so that we can consume it!
  if (inv.items.getField(objId, invFieldObjLoc) ~= invItemLocInventory) then
    retval = inv.items.getItem(objId, commandArray)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.consume.useItem: Failed to get item " .. objId .. ": " .. dbot.retval.getString(retval))
      return retval
    end -- if
  end -- if

  -- Consume the item and wait until we have confirmation the command executed
  if (commandArray ~= nil) then
    table.insert(commandArray, consumeCmd .. " " .. objId)

    -- Items are removed from tracking BEFORE the consume command executes. This is intentional:
    -- it prevents the same item being selected twice in a batch (e.g., quaffing 5 heals in combat).
    -- Waiting for server confirmation would add unacceptable latency in combat scenarios.
    -- Trade-off: if the command fails (lag, AFK), the item is lost from tracking but still exists
    -- in-game. A "dinv refresh" will re-identify it. This trade-off favors combat speed over
    -- perfect tracking accuracy.
    if (itemType == "Potion") or (itemType == "Pill") or (itemType == "Food") then
      retval = inv.items.remove(objId) 
    end -- if
  end -- if

  return retval
end -- inv.consume.useItem



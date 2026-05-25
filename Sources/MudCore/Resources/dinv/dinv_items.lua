----------------------------------------------------------------------------------------------------
-- Item management module: create an inventory table and provide access to it
--
-- Functions:
--   inv.items.init.atInstall
--   inv.items.init.atActive
--   inv.items.fini
--
--   inv.items.save
--   inv.items.load
--   inv.items.reset
--   inv.items.new
--
--   inv.items.getEntry
--   inv.items.setEntry
--   inv.items.getField
--   inv.items.setField
--   inv.items.getStatField
--   inv.items.setStatField
--
--   inv.items.add
--   inv.items.remove
--   inv.items.forget
--   inv.items.forgetCR
--   inv.items.ignore
--   inv.items.ignoreCR
--   inv.items.listIgnored()
--   inv.items.isIgnored(objId)
--
--   inv.items.discoverCR(maxNumItems, refreshLocations)
--   inv.items.discoverLocation
--   inv.items.discoverSetupFn
--
--   inv.items.identifyCR(maxNumItems, refreshLocations)
--   inv.items.identifyItem
--   inv.items.identifyItemSetupFn
--   inv.items.identifyAtomicSetup()
--   inv.items.identifyAtomicCleanup(resultData, retval)
--
--   inv.items.refresh(maxNumItems, refreshLocations, endTag, tagProxy)
--   inv.items.refreshCR
--   inv.items.refreshAtTime
--   inv.items.refreshDefault()
--   inv.items.refreshGetPeriods()
--   inv.items.refreshSetPeriods(autoMin, eagerSec)
--   inv.items.refreshOn(autoMin, eagerSec)
--   inv.items.refreshOff()
--   inv.items.isDirty()
--
--   inv.items.build
--
--   inv.items.get
--   inv.items.getCR
--   inv.items.getItem
-- 
--   inv.items.put
--   inv.items.putCR
--   inv.items.putItem
-- 
--   inv.items.store
--   inv.items.storeCR
--   inv.items.storeItem
-- 
--   inv.items.wearItem(objId, objLoc, commandArray, doCheckLocation)
--   inv.items.wearSetupFn()   
--   inv.items.wearResultFn()
--
--   inv.items.isWorn(objId)
--   inv.items.isWearableLoc(wearableLoc)
--   inv.items.isWearableType(wearableType)
--   inv.items.wearableTypeToLocs(wearableType)
--
--   inv.items.removeItem(objId, commandArray)
--   inv.items.removeSetupFn()   
--   inv.items.removeResultFn()
--
--   inv.items.keyword
--   inv.items.keywordCR
-- 
--   inv.items.search
--   inv.items.searchCR
--   inv.items.sort
--   inv.items.compare
--   inv.items.convertRelative
--   inv.items.convertSetupFn
--
--   inv.items.display
--   inv.items.displayCR
--   inv.items.displayItem
--   inv.items.colorizeStat
--
--   inv.items.isInvis(objId)
--
-- Data:
--    inv.items.table
--    inv.items.stateName -- name for the state file holding the table in persistent storage
----------------------------------------------------------------------------------------------------


-- We don't want to scan worn equipment, the main inventory, and all containers each time that we 
-- do a refresh because that can take 5-10 seconds depending on how many containers you have.
-- Instead, we maintain "clean" or "dirty" flags for each possible place to scan.  At startup, we
-- consider everything to be "dirty" and we require a full scan.  After that, we mark locations as
-- "dirty" when something new is placed at that location.  We can then selectively scan the dirty
-- locations, identify things there, and then mark the newly scanned location as "clean".  This cuts
-- down on refresh overhead significantly.
--
-- If we identify a container from the recent cache, we mark that container as being dirty because
-- we don't know what items are in the container.  Something could have been added or removed since
-- the last time we identified the container.

invItemsRefreshLocAll   = "all"
invItemsRefreshLocWorn  = "worn"
invItemsRefreshLocMain  = "inventory"
invItemsRefreshLocKey   = "keyring"
invItemsRefreshLocDirty = "dirty"

invItemsRefreshClean    = "isScanned"
invItemsRefreshDirty    = "isNotScanned"

inv.items               = {}
inv.items.init          = {}
inv.items.table         = {}


inv.items.mainState     = invItemsRefreshDirty -- state for the main inventory (as detected by invdata)
inv.items.wornState     = invItemsRefreshDirty -- state for items you are wearing (as detected by eqdata)
inv.items.keyringState  = invItemsRefreshDirty -- state for keyring items (as detected by keyring data)

inv.items.burstSize     = 20 -- max # of items that can be moved in one atomic operation


function inv.items.init.atInstall()
  local retval = DRL_RET_SUCCESS

  -- Trigger on invmon
  check (AddTriggerEx(inv.items.trigger.invmonName,
                      "^{invmon}(.*?),(.*?),(.*?),(.*?)$",
                      "inv.items.trigger.invmon(\"%1\",\"%2\",\"%3\",\"%4\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))

  -- Trigger on invitem
  check (AddTriggerEx(inv.items.trigger.invitemName,
                      "^{invitem}(.*?),(.*?),(.*?),(.*?),(.*?),(.*?),(.*?),(.*?)$",
                      "inv.items.trigger.itemDataStats(" ..
                        "\"%1\",\"%2\",\"%3\",\"%4\", \"%5\",\"%6\",\"%7\",\"%8\",true)",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))

  -- Trigger on the start of an identify-ish command (lore, identify, object read, bid, lbid, etc.)
  check (AddTriggerEx(inv.items.trigger.itemIdStartName,
                      "^(" ..
                         ".-----------------------------------------------------------------.*|" ..
                         "\\| Keywords.*|" ..                              -- blindmode: no border
                         "Current bid on this item is.*|"              ..
                         "You do not have that item.*|"                ..
                         "You dream about being able to identify.*|"   ..
                         ".*does not have that item for sale.*|"       ..
                         "There is no auction item with that id.*|"    ..
                         ".*currently holds no inventory.*|"           ..
                         ".* is closed.|"                              ..
                         "There is no marketplace item with that id.*" ..
                      ")$",
                      "inv.items.trigger.itemIdStart(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.itemIdStartName, false)) -- default to off

  -- Trigger on an identification of "A Fantasy Series Card Collector Case", a Winds of Fate epic item.
  -- This is a unique item that claims to be a container but it actually isn't.  It can even be placed
  -- inside other containers.  It also has varying output when identified based on what cards the user
  -- has assigned to it as part of the Winds' epic.
  check (AddTriggerEx(inv.items.trigger.suppressWindsName,
                      "^(" ..
                         "You have the following cards stored:.*|"     ..
                         ".*Fantasy Series Collector\'s Card.*|"       ..
                         "Total: [0-9]+.*"                             ..
                      ")$",
                      "",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.suppressWindsName, false)) -- default to off

  -- Trigger on one of the detail/stat lines of an item's id report (lore, identify, bid, etc.)
  check (AddTriggerEx(inv.items.trigger.itemIdStatsName,
                      "^(" ..
                         "\\| .*\\||" ..
                         ".*A full appraisal will reveal further information on this item.|" ..
                      ")$",
                      "inv.items.trigger.itemIdStats(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.itemIdStatsName, false)) -- default to off

  -- Suppress output messages from the identification (lore, cast identify, cast object read, etc.)
  check (AddTriggerEx(inv.items.trigger.suppressIdMsgName,
                      "^Your natural intuition reveals the item's properties.....*$",
                      "",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.suppressIdMsgName, false)) -- default to off

  -- Trigger on an eqdata, invdata, or keyring data tag
  check (AddTriggerEx(inv.items.trigger.itemDataStartName,
                      "^{(eqdata|invdata|keyring)[ ]?([0-9]+)?}$|^(Item) ([0-9]+) not found.$",
                      "inv.items.trigger.itemDataStart(\"%1\",\"%2\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.itemDataStartName, false)) -- default to off

  -- Trigger on the stats for an eqdata, invdata, or keyring data item
  check (AddTriggerEx(inv.items.trigger.itemDataStatsName,
                      "^([0-9]+?),(.*?),(.*?),(.*?),(.*?),(.*?),(.*?),(.*?)$",
                      "inv.items.trigger.itemDataStats" .. 
                      "(\"%1\",\"%2\",\"%3\",\"%4\", \"%5\",\"%6\",\"%7\",\"%8\",false)",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.itemDataStatsName, false)) -- default to off

  -- Trigger on an identify command to capture the item's object ID
  check (AddTriggerEx(inv.items.trigger.idItemName,
                      "^(" .. 
                         ".------.*|"                                   ..
                         "\\|.*|"                                       ..
                         "You do not have that item.*|"                 ..
                         "You dream about being able to identify.*|"    ..
                         ".*does not have that item for sale.*|"        ..
                         "There is no auction item with that id.*|"     ..
                         ".*currently holds no inventory.*|"            ..
                         "There is no marketplace item with that id.*|" ..
                         inv.items.identifyFence                        ..
                      "|)$", -- accept an empty capture on the last line if there is one there

                      "inv.items.trigger.idItem(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.idItemName, false)) -- default to off

  -- Trigger on "special" wear messages for unique items
  check (AddTriggerEx(inv.items.trigger.wearSpecialName,
                      "^(" ..
                         "You proudly pin.*to your chest."                ..
                         "|Your gloves tighten around.*with a loud snap!" ..
                         "|.* feels like a part of you!"                  ..
                         "|You are skilled with .*"                       ..
                         "|You feel quite confident with .*"              ..
                      ")$",
                      "",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.wearSpecialName, false)) -- default to off

  -- Trigger on the output of the "wear" command
  check (AddTriggerEx(inv.items.trigger.wearName,
                      "^(" ..
                         "You do not have that item.*"           .. -- wear BADNAME
                         "|You wear.*"                           .. -- wear the item
                         "|You wield .*"                         .. -- hold weapon
                         "|You light .*"                         .. -- wear light
                         "|You hold .*"                          .. -- held item
                         "|You equip .*"                         .. -- wear portal or sleeping bag
                         "|.* begins floating around you.*"      .. -- wear float
                         "|.* begins floating above you.*"       .. -- wear aura of trivia
                         "|You dream about being able to wear.*" .. -- you are sleeping
                         "|You cannot wear .*"                   .. -- item type can't be worn
                         "|You must be at least level.*to use.*" .. -- your level is too low
                      ")$",
                      "inv.items.trigger.wear(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.wearName, false)) -- default to off

  -- Trigger on the output of the "remove" command
  check (AddTriggerEx(inv.items.trigger.removeName,
                      "^(" ..
                         "You are not wearing that item."  .. -- remove BADNAME
                         "|You remove .*"                  .. -- wear item
                         "|You stop using .*"              .. -- shield
                         "|You stop holding.*"             .. -- held item
                         "|You stop wielding .*"           .. -- weapon
                         "|.* stops floating around you.*" .. -- float
                         "|.* stops floating above you.*"  .. -- above
                         "|You stop using.* as a portal.*" .. -- portal
                         "|You dream about removing your equipment.*" ..
                      ")$",
                      "inv.items.trigger.remove(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.removeName, false)) -- default to off

  -- Trigger on the output of the "get" command
  check (AddTriggerEx(inv.items.trigger.getName,
                      "^(" ..
                         "You get.*"                            ..
                         "|You do not see.*"                    ..
                         "|You dream about being able to get.*" ..
                      ")$",
                      "inv.items.trigger.get(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.getName, false)) -- default to off

  -- Trigger on the output of the "put" command
  check (AddTriggerEx(inv.items.trigger.putName,
                      "^(" .. 
                         "You don't have that.*"                 ..
                         "|You do not see.*"                     ..
                         "|You dream about putting items away.*" ..
                         "|You put .* into .*"                   ..
                      ")$",
                      "inv.items.trigger.put(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.putName, false)) -- default to off

  -- Trigger on the output of the "keyring get" command
  check (AddTriggerEx(inv.items.trigger.getKeyringName,
                      "^(" ..
                         "You remove.*from your keyring.*"          ..
                         "|You did not find that on your keyring.*" ..
                         "|You dream about being able to keyring.*" ..
                      ")$",
                      "inv.items.trigger.getKeyring(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.getKeyringName, false)) -- default to off

  -- Trigger on the output of the "keyring put" command
  check (AddTriggerEx(inv.items.trigger.putKeyringName,
                      "^(" ..
                         "You put.*on your keyring.*"               ..
                         "|You do not have that item.*"             ..
                         "|You dream about being able to keyring.*" ..
                      ")$",
                      "inv.items.trigger.putKeyring(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.items.trigger.putKeyringName, false)) -- default to off

  return retval

end -- inv.items.init.atInstall


function inv.items.init.atActive()
  local retval = inv.items.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.init.atActive: failed to load items data from storage: " ..
              dbot.retval.getString(retval))
  end -- if

  -- Mark all known containers as not being "clean" (i.e., fully scanned).  Someone could
  -- have logged in without this plugin (or *gasp* used telnet) and moved items or added
  -- and/or removed items.  We need to know exactly what items are actually present and
  -- where those items are.
  --
  -- Note: This isn't a perfect solution because someone may have added a container without
  --       us knowing and we can't mark it as being dirty if we don't know it exists.  However,
  --       this is largely redundant with the full scan we do when we init the plugin and it
  --       is essentially just a backup way of handling things if the user stops the full scan
  --       for some reason.
  for objId, _ in pairs(inv.items.table) do
    if (inv.items.getStatField(objId, invStatFieldType) == invmon.typeStr[invmonTypeContainer]) then
      inv.items.setField(objId, invFieldIdentifyLevel, invIdLevelNone)
      inv.items.keyword(invItemsRefreshClean, invKeywordOpRemove, "id " .. objId, true)
    end -- if
  end -- for

  -- If automatic refreshes are enabled (i.e., the period is > 0 minutes), kick off the 
  -- refresh timer to periodically scan our inventory and update the inventory table
  local refreshPeriod = inv.items.refreshGetPeriods() or inv.items.timer.refreshMin
  if (refreshPeriod > 0) then
    inv.items.refreshAtTime(refreshPeriod, 0)
  else
    dbot.deleteTimer(inv.items.timer.refreshName)
  end -- if

  return retval
end -- inv.items.init.atActive


function inv.items.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  dbot.deleteTrigger(inv.items.trigger.invmonName)
  dbot.deleteTrigger(inv.items.trigger.invitemName)
  dbot.deleteTrigger(inv.items.trigger.itemIdStartName)
  dbot.deleteTrigger(inv.items.trigger.suppressWindsName)
  dbot.deleteTrigger(inv.items.trigger.itemIdStatsName)
  dbot.deleteTrigger(inv.items.trigger.suppressIdMsgName)
  dbot.deleteTrigger(inv.items.trigger.itemDataStartName)
  dbot.deleteTrigger(inv.items.trigger.itemDataStatsName)
  dbot.deleteTrigger(inv.items.trigger.idItemName)
  dbot.deleteTrigger(inv.items.trigger.wearSpecialName)
  dbot.deleteTrigger(inv.items.trigger.wearName)
  dbot.deleteTrigger(inv.items.trigger.removeName)
  dbot.deleteTrigger(inv.items.trigger.getName)
  dbot.deleteTrigger(inv.items.trigger.putName)
  dbot.deleteTrigger(inv.items.trigger.getKeyringName)
  dbot.deleteTrigger(inv.items.trigger.putKeyringName)

  dbot.deleteTimer(inv.items.timer.refreshName)
  dbot.deleteTimer(inv.items.timer.idTimeoutName)

  if (doSaveState) then
    -- Save our current data
    retval = inv.items.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.items.fini: Failed to save inv.items module data: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  inv.items.fullScanCompleted = false

  return retval
end -- inv.items.fini


function inv.items.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  if not inv.items.table then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM items")

    for objId, entry in pairs(inv.items.table) do
      local query = dinv_db.buildItemInsert("items", objId, entry)
      db:exec(query)
      if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
        dbot.warn("inv.items.save: Failed to save item " .. tostring(objId))
        return DRL_RET_INTERNAL_ERROR
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- inv.items.save


function inv.items.load()
  local db = dinv_db.handle
  if not db then
    inv.items.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any items exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM items") do
    count = row.cnt
  end

  if count == 0 then
    inv.items.table = {}
    return DRL_RET_SUCCESS
  end

  inv.items.table = {}
  for row in db:nrows("SELECT * FROM items") do
    local entry = dinv_db.rowToItemEntry(row)
    inv.items.table[row.obj_id] = entry
  end

  return DRL_RET_SUCCESS
end -- inv.items.load


function inv.items.reset()
  inv.items.table = {}

  return inv.items.save()
end -- inv.items.reset


function inv.items.new(objId)
  assert(objId ~= nil, "inv.items.new: objId is nil")

  inv.items.table[objId] = {}
  inv.items.table[objId][invFieldIdentifyLevel] = invIdLevelNone
  inv.items.table[objId][invFieldObjLoc] = invItemLocUninitialized
  inv.items.table[objId][invFieldColorName] = ""
  inv.items.table[objId][invFieldStats] = {}

  return DRL_RET_SUCCESS
end -- inv.items.new


function inv.items.getEntry(objId)
  assert(objId ~= nil, "inv.items.getEntry: objId is nil")

  -- dbot.debug("inv.items.getEntry: retrieved item " .. objId)

  return inv.items.table[objId]
end -- inv.items.getEntry


function inv.items.setEntry(objId, entry)
  assert(objId ~= nil, "inv.items.setEntry: objId is nil")

  inv.items.table[objId] = entry
  -- dbot.debug("inv.items.setEntry: updated item " .. objId)

  return DRL_RET_SUCCESS
end -- inv.items.setEntry


invFieldIdentifyLevel = "identifyLevel"
invFieldObjLoc        = "objectLocation"
invFieldHomeContainer = "homeContainer"
invFieldColorName     = "colorName"
invFieldStats         = "stats"

function inv.items.getField(objId, field)
  -- Check the params
  assert((objId ~= nil) and (field ~= nil), "inv.items.getField: nil parameters")
  objId = tonumber(objId)
  assert((objId ~= nil), "Invalid non-numeric objId detected")

  local entry = inv.items.getEntry(objId)
  if (entry == nil) then
    dbot.debug("inv.items.getField: Failed to get field \"" .. field .. "\", entry " .. objId .. 
               " does not exist")
    return nil,DRL_RET_MISSING_ENTRY
  end -- if

  return entry[field], DRL_RET_SUCCESS
end -- inv.items.getField


function inv.items.setField(objId, field, value)
  -- Check the params
  assert((objId ~= nil) and (field ~= nil) and (value ~= nil), "inv.items.setField: nil parameters")
  objId = tonumber(objId) 
  assert((objId ~= nil), "Invalid non-numeric objId detected")

  local entry = inv.items.getEntry(objId)
  if (entry == nil) then
    dbot.warn("inv.items.setField: Failed to set field \"" .. field .. "\", entry " .. objId .. 
              " does not exist")
    return DRL_RET_MISSING_ENTRY
  end -- if

  -- Update the field
  entry[field] = value

  return DRL_RET_SUCCESS
end -- inv.items.setField


function inv.items.getStatField(objId, field)
  objId = tonumber(objId or "")
  if (objId == nil) then
    dbot.warn("inv.items.getStatField: objId parameter is missing")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  if (field == nil) or (field == "") then
    dbot.warn("inv.items.getStatField: field parameter is missing")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  local entry = inv.items.table[objId]
  if (entry == nil) then
    dbot.debug("inv.items.getStatField failed: no inventory entry found for objectID " .. objId .. 
               " for field " .. (field or "nil"))
    return nil, DRL_RET_MISSING_ENTRY
  end -- if

  if (entry.stats == nil) then
    dbot.warn("inv.items.getStatField: Missing stats for objectID " .. objId)
    return nil, DRL_RET_UNIDENTIFIED
  end -- if

  return entry.stats[field], DRL_RET_SUCCESS
end -- inv.items.getStatField


function inv.items.setStatField(objId, field, value) 

  assert(objId ~= nil, "inv.items.setStatField: nil objId parameter")
  assert(field ~= nil, "inv.items.setStatField: nil field parameter for item " .. objId)
  assert(value ~= nil, "inv.items.setStatField: nil value parameter for item " .. objId)

  local entry = inv.items.table[objId]
  if (entry == nil) then
    dbot.warn("inv.items.setStatField failed: no inventory entry found for objectID " .. objId)
    dbot.debug("Attempted to set field " .. field .. " to value \"" .. (value or "nil"))
    return DRL_RET_MISSING_ENTRY
  end -- if

  entry.stats[field] = value

  return DRL_RET_SUCCESS

end -- inv.items.setStatField


-- Look up an item template by basic name (no commas) in the SQLite items table.
-- Returns a fresh item entry suitable for adoption by a new objId, or nil if no
-- matching row exists.  Used as a fallback when the in-memory frequent cache
-- misses (e.g., the user just acquired the first instance of an item whose
-- template predates the frequent cache being populated this session).  Both
-- sides of the comparison are normalized because invitem/invdata strip commas
-- from names while items.name preserves them from the full identify output.
function inv.items.lookupTemplateBySql(basicName)
  local db = dinv_db.handle
  if (db == nil) or (basicName == nil) or (basicName == "") then
    return nil
  end -- if

  -- Exclude unidentified stub rows.  invmon stubs are persisted to the items
  -- table (identify_level='none') so consume display/get can find consumables
  -- before a full ID lands, but a stub carries no real stats -- adopting one as
  -- a "template" leaves the item unidentified and (worse) seeds the frequent
  -- cache with a none-level entry that double-identifies forever.
  local query = string.format(
    "SELECT * FROM items WHERE REPLACE(name, ',', '') = %s AND identify_level <> %s LIMIT 1",
    dinv_db.fixsql(basicName), dinv_db.fixsql(invIdLevelNone))

  for row in db:nrows(query) do
    return dinv_db.rowToItemEntry(row)
  end -- for

  return nil
end -- inv.items.lookupTemplateBySql


function inv.items.add(objId)
  local retval = DRL_RET_SUCCESS
  local objIdNum = tonumber(objId)

  if (objIdNum == nil) then
    dbot.warn("inv.items.add: Failed to add non-numeric objId " .. objId)
    return DRL_RET_INVALID_PARAM
  end -- if

  -- Check if we can pull details on this item instance from the "recently removed"
  -- item cache.  If we can, do it :)  Otherwise, start a new entry for this objId.
  local entry = inv.cache.get(inv.cache.recent.table, objId)
  if (entry == nil) then
    retval = inv.items.new(objId)
  else
    retval = inv.items.setEntry(objId, dbot.table.getCopy(entry))
    if (retval == DRL_RET_SUCCESS) then
      dbot.debug("Added \"" .. (inv.items.getField(objId, invFieldColorName) or "Unidentified") .. 
               DRL_ANSI_WHITE .. "\" (" .. objId .. ") from recent item cache")

      -- The item is now in our inventory table so we can remove it from the recent item cache
      retval = inv.cache.remove(inv.cache.recent.table, objId)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.items.add: Failed to remove " .. objId .. " from recent item cache: " ..
                dbot.retval.getString(retval))
      end -- if

      -- Persist the restored entry back to SQLite. inv.items.remove deletes the DB row
      -- whenever it drops an item from memory, so without this a compare/re-add cycle
      -- would leave the in-memory table and the DB out of sync.
      dinv_db.saveItem(objId, inv.items.table[objId])

      -- If the new item is a container, mark it as "dirty" so that we will rescan it on the
      -- next discovery phase of a refresh, and re-add any items that were inside the
      -- container at remove time.  When a container leaves the player's inventory (e.g.,
      -- dropped on death), inv.items.remove cascades recursively and caches every item
      -- inside in the recent-items cache.  When the container comes back, Aardwolf only
      -- emits an invmon event for the container itself -- items inside stay inside
      -- server-side and never re-emit.  Walking the recent cache here restores them
      -- immediately, without depending on a refresh (most players run with refresh off).
      if (inv.items.getStatField(objId, invStatFieldType) == invmon.typeStr[invmonTypeContainer]) then
        inv.items.keyword(invItemsRefreshClean, invKeywordOpRemove, "id " .. objId, true)

        local nestedIds = {}
        if (inv.cache.recent.table ~= nil) and (inv.cache.recent.table.entries ~= nil) then
          for cachedId, cachedRecord in pairs(inv.cache.recent.table.entries) do
            if (cachedRecord ~= nil) and (cachedRecord.entry ~= nil) and
               (cachedRecord.entry[invFieldObjLoc] == objId) then
              table.insert(nestedIds, cachedId)
            end -- if
          end -- for
        end -- if
        for _, nestedId in ipairs(nestedIds) do
          inv.items.add(nestedId)  -- recurses into this logic if nestedId is a container
        end -- for

        -- Backstop: schedule an eager refresh in case any item was pruned from the recent
        -- cache (1000-entry LRU) before we got here.  No-op for players with refresh off.
        local eagerRefreshSec = tonumber(inv.config.table.refreshEagerSec or 0)
        if (inv.state == invStateIdle) and (eagerRefreshSec > 0) then
          inv.items.refreshAtTime(0, eagerRefreshSec)
        end -- if
      end -- if
    end -- if
  end -- if

  return retval
end -- inv.items.add


function inv.items.remove(objId, fromCascade)
  local retval = DRL_RET_SUCCESS

  local item = inv.items.getEntry(objId)
  if (item == nil) then
    dbot.warn("inv.items.removeFailed to remove item " .. objId ..
              " from inventory table because it is not in the table")
    return DRL_RET_MISSING_ENTRY
  end -- if

  -- Remove any item whose location matches the objId for the removed item (it could be a container)
  -- It would be nice if we could prune the search a bit and only do this if the item is a container.
  -- Unfortunately, we can't be guaranteed that the item is identified enough for us to know it is a
  -- container so we must do this for every item.  It's a bit more overhead...oh well.
  --
  -- The recursive call passes fromCascade=true so the recent-cache add below
  -- doesn't skip frequent-cache items in this descent.  When a container is
  -- dropped (e.g., on death) we need every nested item -- including potions and
  -- other frequent-cache consumables -- in the recent cache so the container
  -- restore walk in inv.items.add can re-link them.  Without this, a bag full
  -- of healing potions came back empty after a death-retrieval cycle and the
  -- only recovery was "dinv refresh all".
  for k,v in pairs(inv.items.table) do
    if (v[invFieldObjLoc] ~= nil) and (v[invFieldObjLoc] == objId) then
      dbot.debug("Removed item " .. k .. " from removed container " .. objId)
      inv.items.remove(k, true)
    end -- if
  end -- for

  -- Cache the removed item in the "recently removed" cache so we can re-identify
  -- it cheaply if it comes back soon.  Top-level removes skip items already
  -- represented in the frequent cache (potions, pills, scrolls, etc.) -- the
  -- frequent cache has the identification template by name and the recent
  -- cache would only duplicate it per-objId.  Cascade removes (fromCascade
  -- true) DO cache every item regardless: the per-objId entry is the only
  -- record of which container the item belonged to, and inv.items.add reads
  -- cachedRecord.entry.objectLocation on container retrieval to re-link nested
  -- items.
  local name = inv.items.getStatField(objId, invStatFieldName)
  if (name ~= nil) and (fromCascade or
                        (inv.cache.get(inv.cache.frequent.table, name) == nil)) then
    retval = inv.cache.add(inv.cache.recent.table, objId)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.items.remove: failed to cache \"" ..
                (inv.items.getField(objId, invFieldColorName) or "Unidentified") ..
                "\" in recently removed item cache: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  -- Whack the entry we just removed
  inv.items.setEntry(objId, nil)

  -- Keep the SQLite items table in sync with the in-memory table. Without this,
  -- callers that query SQLite directly (e.g., inv.consume.displayType) see stale
  -- rows until a full refresh.
  dinv_db.deleteItem(objId)

  return retval
end -- inv.items.remove


inv.items.forgetPkg = nil
function inv.items.forget(query, endTag)

  if (inv.items.forgetPkg ~= nil) then
    dbot.note("Skipping forget request: another forget request is in progress")
    return inv.tags.stop(invTagsForget, endTag, DRL_RET_BUSY)
  end -- if

  inv.items.forgetPkg        = {}
  inv.items.forgetPkg.query  = query or ""
  inv.items.forgetPkg.endTag = endTag

  wait.make(inv.items.forgetCR)

  return DRL_RET_SUCCESS
end -- inv.items.forget


function inv.items.forgetCR()

  if (inv.items.forgetPkg == nil) or (inv.items.forgetPkg.query == nil) then
    dbot.error("inv.items.forgetCR: Aborting forget request -- forget package or query is nil!")
    inv.items.forgetPkg = nil
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local endTag = inv.items.forgetPkg.endTag

  local idArray, retval = inv.items.searchCR(inv.items.forgetPkg.query)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.forgetCR: failed to search inventory table: " .. dbot.retval.getString(retval))

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    dbot.info("No match found for forget query: \"" .. inv.items.forgetPkg.query .. "\"")

  -- Forget everything that matched the query by removing it from the inventory table and cache
  else
    for _, objId in ipairs(idArray) do
      dbot.note("Forgetting item \"" .. (inv.items.getField(objId, invFieldColorName) or "Unknown") .. "@W\"")
      inv.items.remove(objId)
      inv.cache.remove(inv.cache.recent.table, objId)
    end -- for

    dbot.info("Forgot " .. #idArray .. " items: run \"@Gdinv refresh all@W\" to rescan your inventory.")
  end -- if

  -- Save our changes so that they don't get picked up again accidentally if we reload the plugin
  inv.items.save()

  inv.items.forgetPkg = nil

  return inv.tags.stop(invTagsForget, endTag, retval)
end -- inv.items.forgetCR


inv.items.ignorePkg = nil
inv.items.ignoreFlag = "dinvIgnore"
function inv.items.ignore(mode, container, endTag)

  if (inv.items.ignorePkg ~= nil) then
    dbot.note("Skipping ignore request: another ignore request is in progress")
    return inv.tags.stop(invTagsIgnore, endTag, DRL_RET_BUSY)
  end -- if

  inv.items.ignorePkg           = {}
  inv.items.ignorePkg.mode      = mode or ""
  inv.items.ignorePkg.container = container or ""
  inv.items.ignorePkg.endTag    = endTag

  wait.make(inv.items.ignoreCR)

  return DRL_RET_SUCCESS
end -- inv.items.ignore


function inv.items.ignoreCR()
  local retval = DRL_RET_SUCCESS

  if (inv.items.ignorePkg == nil) then
    dbot.error("inv.items.ignoreCR: Aborting ignore request -- ignore package is nil!")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local endTag = inv.items.ignorePkg.endTag

  -- Check that the ignore mode is valid
  local modeStr
  local lowerMode = string.lower(inv.items.ignorePkg.mode or "")
  if (lowerMode == "on") then
      modeStr = "@GON@W"
  elseif (lowerMode == "off") then
      modeStr = "@ROFF@W"
  else
    dbot.warn("inv.items.ignoreCR: Invalid ignore mode \"" .. (inv.items.ignorePkg.mode or "nil") .. "\"")
    inv.items.ignorePkg = nil
    return inv.tags.stop(invTagsIgnore, endTag, DRL_INVALID_PARAM)
  end -- if

  if (invItemLocKeyring == string.lower(inv.items.ignorePkg.container)) then
    if (lowerMode == "on") then
      inv.config.table.doIgnoreKeyring = true
    else
      inv.config.table.doIgnoreKeyring = false
    end -- if

    -- Save the config change that indicates if we are ignoring the keyring
    retval = inv.config.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.items.ignoreCR: Failed to save inv.config module data: " ..
                dbot.retval.getString(retval))
    else
      dbot.info("Ignore mode for keyring \"" .. inv.items.ignorePkg.container .. "\" is " .. modeStr)    
    end -- if

  -- We are targeting a container, not the keyring
  else

    -- Check if the container is in the inventory table or if more than one item matches the description
    local idArray, retval = inv.items.searchCR("rname " .. inv.items.ignorePkg.container, true)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.items.ignoreCR: failed to search inventory table: " .. dbot.retval.getString(retval))

    elseif (#idArray > 1) then
      dbot.warn("inv.items.ignoreCR: More than one item matched container \"" ..
                inv.items.ignorePkg.container .. "\"")
      retval = DRL_RET_INTERNAL_ERROR
    end -- if

    local containerId = ""

    -- If the container isn't in the inventory table yet, get its objID and add a stub for it into
    -- the inventory table.  The stub will be enough to add the ignore flag later in this function
    -- and the user can pick up a full identification on a refresh if they ever remove the ignore flag.
    if (idArray == nil) or (#idArray == 0) then
      _, containerId, retval = inv.items.convertRelative(invQueryKeyRelativeName,
                                                         inv.items.ignorePkg.container)
      containerId = tonumber(containerId or "")
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.items.ignoreCR: Failed to convert relative name \"" .. inv.items.ignorePkg.container ..
                  "\" to object ID: " .. dbot.retval.getString(retval))

      elseif (containerId == nil) then
        dbot.info("No match found for ignore container: \"" .. inv.items.ignorePkg.container .. "\"")
        retval = DRL_RET_MISSING_ENTRY

      else
        -- Ok, we finally have enough info to add a stub for this container
        retval = inv.items.add(containerId)
        if (retval == DRL_RET_SUCCESS) then
          inv.items.setStatField(containerId, invStatFieldType, invmon.typeStr[invmonTypeContainer])
          inv.items.setStatField(containerId, invStatFieldId, containerId)
        else
          dbot.warn("inv.items.ignoreCR: Failed to add container stub to inventory table: " ..
                    dbot.retval.getString(retval))
        end -- if

      end -- if

    else
      -- We found a valid container that was already in our inventory table
      containerId = idArray[1]
    end -- if

    -- Set or clear the ignore flag for the specified container
    if (retval == DRL_RET_SUCCESS) then
      dbot.debug("Setting ignore to \"" .. modeStr .. "\" for item " .. containerId)

      if (inv.items.getStatField(containerId, invStatFieldType) ~= invmon.typeStr[invmonTypeContainer]) then
        dbot.warn("inv.items.ignoreCR: item \"" .. inv.items.ignorePkg.container .. "\" is not a container")
        retval = DRL_INVALID_PARAM

      elseif (lowerMode == "on") then
        retval = inv.items.keyword(inv.items.ignoreFlag, invKeywordOpAdd, "id " .. containerId, true, nil)

      elseif (lowerMode == "off") then
        retval = inv.items.keyword(inv.items.ignoreFlag, invKeywordOpRemove, "id " .. containerId, true, nil)

      end -- if

      dbot.info("Ignore mode for container \"" .. inv.items.ignorePkg.container .. "\" is " .. modeStr)
    end -- if
  end -- if

  -- Save our changes so that they don't get picked up again accidentally if we reload the plugin
  inv.items.save()

  inv.items.ignorePkg = nil

  return inv.tags.stop(invTagsIgnore, endTag, retval)
end -- inv.items.ignoreCR


function inv.items.listIgnored()

  local numIgnored = 0

  dbot.print("@WIgnored Locations:@w")

  if inv.config.table.doIgnoreKeyring then
    dbot.print("    @WKeyring@w")
    numIgnored = numIgnored + 1
  end -- if

  for objId, itemEntry in pairs(inv.items.table) do
    if (inv.items.getStatField(objId, invStatFieldType) == invmon.typeStr[invmonTypeContainer]) and
       inv.items.isIgnored(objId) then
      dbot.print("    " .. inv.items.getField(objId, invFieldColorName) .. " (" .. objId .. ")")
      numIgnored = numIgnored + 1
    end -- if
  end -- for

  if (numIgnored == 0) then
    dbot.print("    None")
  end -- if

  dbot.print("")

  local suffix = "s"
  if (numIgnored == 1) then
    suffix = ""
  end -- if
  
  dbot.info("Currently ignoring " .. numIgnored .. " location" .. suffix)

  return DRL_RET_SUCCESS

end -- inv.items.listIgnored


-- An item is "ignored" if it has the inv.items.ignoreFlag or if it is in a container that has
-- the inv.items.ignoreFlag.  We can also mark the keyring as ignored.
function inv.items.isIgnored(objId)
  if (objId == nil) or (tonumber(objId or "") == nil) or (inv.items.getEntry(objId) == nil) then
    return false
  end -- if

  local keywords = inv.items.getStatField(objId, invStatFieldKeywords) or ""
  local objLoc   = inv.items.getField(objId, invFieldObjLoc)

  if dbot.isWordInString(inv.items.ignoreFlag, keywords) then
    -- If the the item has the ignore flag, it is ignored
    return true

  elseif (objLoc == invItemLocKeyring) then
    -- If the item is on the keyring, we ignore the item if the keyring is ignored
    return inv.config.table.doIgnoreKeyring

  else
    -- Check if the object is in a container and, if so, if that container is ignored
    return inv.items.isIgnored(tonumber(objLoc) or "")

  end -- if

end -- inv.items.isIgnored


function inv.items.discoverCR(maxNumItems, refreshLocations)
  local retval

  -- If maxNumItems isn't given, default to 0 -- which means there is no maximum
  maxNumItems = tonumber(maxNumItems or 0) or 0

  -- If refreshLocations is not given, default to scanning everything
  refreshLocation = refreshLocations or invItemsRefreshLocAll

  -- Discover equipment that is currently worn.  We only do this if the user asked to scan "all"
  -- locations, if the user specifically asked to scan "worn" locations, or if the user asked to
  -- scan dirty locations and worn locations are marked as dirty because we haven't yet scanned them.
  if (refreshLocation == invItemsRefreshLocAll) or
     (refreshLocation == invItemsRefreshLocWorn) or
     ((refreshLocation == invItemsRefreshLocDirty) and (inv.items.wornState == invItemsRefreshDirty)) then
    retval = inv.items.discoverLocation(invItemLocWorn)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.debug("inv.items.discoverCR: Failed to discover worn equipment: " .. dbot.retval.getString(retval))
      return retval
    else
      inv.items.wornState = invItemsRefreshClean
    end -- if
  end -- if

  -- Discover items in the main inventory
  if (refreshLocation == invItemsRefreshLocAll) or 
     (refreshLocation == invItemsRefreshLocMain) or
     ((refreshLocation == invItemsRefreshLocDirty) and (inv.items.mainState == invItemsRefreshDirty)) then
    retval = inv.items.discoverLocation(invItemLocInventory)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.debug("inv.items.discoverCR: Failed to discover main inventory contents: " .. 
                 dbot.retval.getString(retval))
      return retval
    else
      inv.items.mainState = invItemsRefreshClean
    end -- if
  end -- if

  -- Discover items in the keyring
  if (refreshLocation == invItemsRefreshLocAll) or 
     (refreshLocation == invItemsRefreshLocKey) or
     ((refreshLocation == invItemsRefreshLocDirty) and (inv.items.keyringState == invItemsRefreshDirty)) then
    retval = inv.items.discoverLocation(invItemLocKeyring)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.debug("inv.items.discoverCR: Failed to discover keyring contents: " .. 
                 dbot.retval.getString(retval))
      return retval
    else
      inv.items.keyringState = invItemsRefreshClean
    end -- if
  end -- if

  -- Identify everything discovered so far (we mainly just want to find containers so that we can discover
  -- their contents next)
  retval = inv.items.identifyCR(maxNumItems, refreshLocations)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("inv.items.discoverCR: Inventory identification did not complete: " .. 
               dbot.retval.getString(retval))
    return retval
  end -- if

  -- Discover all containers
  if (refreshLocation == invItemsRefreshLocAll) or (refreshLocation == invItemsRefreshLocDirty) then
    for objId,v in pairs(inv.items.table) do
      local itemOwner, pretitle = dbot.gmcp.getName()
      local ownedBy = inv.items.getStatField(objId, invStatFieldOwnedBy)

      -- If this is a container that we own, try to discover everything in it.  Don't try to discover
      -- items if we don't own the container because we can't access it anyway.  If there isn't an
      -- ownership field for the item, assume we own it since it doesn't belong to anyone else that
      -- we know of.
      if (inv.items.getStatField(objId, invStatFieldType) == invmon.typeStr[invmonTypeContainer]) and
         ((ownedBy == nil) or (ownedBy == "") or (ownedBy == itemOwner)) then

        -- Scan this container if the caller asked us to scan everything or if we need to scan all
        -- dirty containers and this container is dirty (i.e., it hasn't been verified to be clean 
        -- in a previous scan)
        local keywordField = inv.items.getStatField(objId, invStatFieldKeywords) or ""
        if (refreshLocation == invItemsRefreshLocAll) or
           ((refreshLocation == invItemsRefreshLocDirty) and 
            (not dbot.isWordInString(invItemsRefreshClean, keywordField))) then
          dbot.debug("Discovering contents of container " .. objId .. ": " .. v[invFieldColorName])

          -- Discover items in the container
          retval = inv.items.discoverLocation(objId)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.debug("inv.items.discoverCR: Failed to discover container " .. objId .. 
                       ": " .. dbot.retval.getString(retval))
          else
            inv.items.keyword(invItemsRefreshClean, invKeywordOpAdd, "id " .. objId, true)
          end -- if
        end -- if
      end -- if
    end -- for
  end -- if

  return retval
end -- inv.items.discoverCR


drlInvDiscoveryTimeoutThresholdSec = 30 -- make this large enough to handle a speedwalk in the middle
function inv.items.discoverLocation(location)
  local retval
  local containerId

  -- Valid discovery locations are worn equipment, main inventory, the keyring, or a container
  if (location ~= nil) then
    containerId = tonumber(location)
  end -- if
  assert((location == invItemLocWorn) or (location == invItemLocInventory) or 
         (location == invItemLocKeyring) or (containerId ~= nil),
         "inv.items.discoverLocation: invalid location parameter")

  -- Only allow one discovery request at a time
  if (inv.items.discoverPkg ~= nil) then
    dbot.note("Skipping inventory discovery because another discovery is in progress")
    return DRL_RET_BUSY
  end -- if

  inv.items.discoverPkg = {}

  -- Start the discovery!!!
  local command
  if (location == invItemLocWorn) then
    command = "eqdata"
  elseif (location == invItemLocInventory) then
    command = "invdata"
  elseif (location == invItemLocKeyring) then
    command = "keyring data"
  else
    command = "invdata " .. containerId
  end -- if

  local resultData = dbot.callback.new()
  retval = dbot.execute.safe.command(command, inv.items.discoverSetupFn, nil,
                                     dbot.callback.default, resultData)
  if (retval ~= DRL_RET_SUCCESS) then
    if (retval ~= DRL_RET_IN_COMBAT) then
      dbot.warn("inv.items.discoverLocation: Failed to execute command \"@G" .. command .. "@W\": " ..
                dbot.retval.getString(retval))
    end -- if
    inv.items.trigger.itemDataEnd() -- Call this to clean up any lingering state from the failed discovery
    return retval
  end -- if

  -- Wait for the callback to confirm that the safe execution completed
  retval = dbot.callback.wait(resultData, drlInvDiscoveryTimeoutThresholdSec)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.note("Inventory discovery did not complete: " .. dbot.retval.getString(retval) ..
              ".  We'll try again later.")
    inv.items.trigger.itemDataEnd() -- Call this to clean up any lingering state from the failed discovery
  end -- if

  -- Wait until the eqdata, invdata, keyring data triggers complete
  if (retval == DRL_RET_SUCCESS) then
    local timeout = 0
    while (inv.items.discoverPkg ~= nil) do
      wait.time(drlSpinnerPeriodDefault)
      timeout = timeout + drlSpinnerPeriodDefault
      if (timeout > 2) then -- use a short timeout since the callback.wait() call above already waited a while
        dbot.note("Inventory discovery timed out -- maybe you were busy.  We'll try again later...")
        inv.items.trigger.itemDataEnd() -- Call this to clean up any lingering state from the failed discovery
        return DRL_RET_TIMEOUT
      end -- if
    end -- while
  end -- if

  return retval
end -- inv.items.discoverLocation


function inv.items.discoverSetupFn()
  EnableTrigger(inv.items.trigger.itemDataStartName, true)
end -- inv.items.discoverSetupFn


function inv.items.identifyCR(maxNumItems, refreshLocations)
  local retval = DRL_RET_SUCCESS

  -- NOTE: Partial refresh (capping items per call, limiting to specific containers) was considered
  -- but deferred. With incremental saves during identification (v3.0031), crash resilience is
  -- already addressed. Partial refresh adds complexity (tracking what's been refreshed, resuming)
  -- for modest benefit. Revisit only if users routinely have 1000+ item inventories.
  -- For now, we ignore the "maxNumItems" and "refreshLocations" parameters.

  -- Count the number of items to identify and keep a record of which items require identification.
  -- We use a temporary array for the objIds of these items so that we can avoid walking the entire
  -- inventory table again and so that we don't need to handle the case where item idLevel changes
  -- during identification.  For example, if the user removes an unidentified item from a container,
  -- we mark the container as unidentified so that we can pick up the current weight statistics on
  -- the next identification.  That scenario complicates things because we could get into a situation
  -- where we pull lots of unidentified items from a container and then immediately re-identify the
  -- container after each one.  The current implementation avoids that entirely by determining up front
  -- which items should be identified during this identification pass.
  local objsToIdentify = {}
  local numItemsToIdentify = 0
  for objId, _ in pairs(inv.items.table) do
    local idLevel = inv.items.getField(objId, invFieldIdentifyLevel)
    if (idLevel ~= nil) and (idLevel == invIdLevelNone) and (not inv.items.isIgnored(objId)) then
      numItemsToIdentify = numItemsToIdentify + 1
      table.insert(objsToIdentify, objId)
    end -- if
  end -- for

  local numItemsIdentified = 0
  for _, objId in ipairs(objsToIdentify) do
    -- Stop and return if we if the user requested that we disable the refresh
    if (inv.state == invStatePaused) then
      retval = DRL_RET_HALTED
      break
    end -- if

    -- Stop and return if we are not in the "active" state.  We don't want to try identifying
    -- things when we are AFK, writing a note, sleeping, running, etc.
    local charState = dbot.gmcp.getState()
    if (charState ~= dbot.stateActive) then
      dbot.note("Skipping remainder of identification request: you are now in state \"" ..
                dbot.gmcp.getStateString(charState) .. "\"")
      if (charState == dbot.stateCombat) then
        retval = DRL_RET_IN_COMBAT
      else
        retval = DRL_RET_NOT_ACTIVE
      end -- if
      break
    end -- if

    -- Attempt to get both the colorized name and the regular name for the item.  If we have
    -- the colorized name, we can get the regular name by stripping the colors from the colorized
    -- version of the name.
    local colorName = inv.items.getField(objId, invFieldColorName) 
    if (colorName == "") then
      colorName = nil
    end -- if
    local name = inv.items.getStatField(objId, invStatFieldName)
    if (name == nil) or (name == "") then
      if (colorName ~= nil) then
        name = strip_colours(colorName)
      else
        name = nil
      end -- if
    end -- if

    -- Check if we can get details on this item from the "frequently acquired" item cache.
    -- If it is in the cache, use the cached copy instead of manually identifying it.
    local idLevel = inv.items.getField(objId, invFieldIdentifyLevel)
    if (idLevel ~= nil) and (idLevel == invIdLevelNone) and (name ~= nil) then

      -- invdata strips out commas in the names of items.  As a result, we won't find items in
      -- the cache unless we also store them in a form without commas.
      name = string.gsub(name, ",", "")

      local cachedEntry = inv.cache.get(inv.cache.frequent.table, name)
      if (cachedEntry ~= nil) then
        -- The cached entry doesn't know the actual location of this object or the object's actual
        -- object ID.  We overwrite those fields here with the correct values for the item.
        cachedEntry[invFieldObjLoc] = inv.items.getField(objId, invFieldObjLoc)
        cachedEntry[invFieldColorName] = colorName
        cachedEntry[invFieldStats].id = objId

        retval = inv.items.setEntry(objId, (cachedEntry))
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.items.identifyCR: Failed to set \"" .. name .. DRL_ANSI_WHITE .. 
                    "\" from frequent cache entry: " .. dbot.retval.getString(retval))
        else
          numItemsIdentified = numItemsIdentified + 1        
          dbot.note("Identify (" .. numItemsIdentified .. " / " .. numItemsToIdentify ..
                    "): \"" .. (colorName or name or "Unidentified") .. "@W" .. DRL_ANSI_WHITE .. 
                    "\" (" .. objId .. ") from frequent cache")
        end -- if
      end -- if
    end -- if

    -- If we don't have any identification completed yet, do a basic ID
    idLevel = inv.items.getField(objId, invFieldIdentifyLevel)
    if (idLevel ~= nil) and (idLevel == invIdLevelNone) then
      local resultData = dbot.callback.new()
      numItemsIdentified = numItemsIdentified + 1
      dbot.note(string.format("Identify (%d / %d)", numItemsIdentified, numItemsToIdentify) ..
                ": \"" .. (colorName or name or "Unidentified") .. "@W" .. DRL_ANSI_WHITE .. 
                "\" (" .. objId .. ")")
      local commandArray = dbot.execute.new()
      retval = inv.items.identifyItem(objId, idCommandBasic, resultData, commandArray)      

      -- Wait until we have confirmation the identification completed
      if (retval == DRL_RET_SUCCESS) then
        if (commandArray ~= nil) then
          retval = dbot.execute.safe.blocking(commandArray, inv.items.identifyAtomicSetup, nil,
                                              inv.items.identifyAtomicCleanup, 10)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.note("Skipping request to identify item \"" .. (colorName or name or "Unidentified") ..
                      "@W" .. DRL_ANSI_WHITE .. "\": " .. dbot.retval.getString(retval))
          end -- if
        else
          local timeout = 0
          while (resultData.isDone == false) do
            wait.time(inv.items.timer.idTimeoutPeriodSec)
            timeout = timeout + inv.items.timer.idTimeoutPeriodSec
            if (timeout > inv.items.timer.idTimeoutThresholdSec) then
              dbot.warn("inv.items.identifyCR: Basic identification timed out for item " .. objId  .. 
                        ": \"" .. (colorName or name or "Unidentified") .. DRL_ANSI_WHITE .. "\"")
              break
            end -- if
          end -- while
        end -- if
      end -- if
    end -- if

    -- If the item is an instance of a frequently acquired item (potion, pill, etc.) add it
    -- to the "frequently acquired item" cache if it is not already in the cache.
    -- Grab the latest name because it may have been filled in during the ID
    name = inv.items.getStatField(objId, invStatFieldName) 
    if (name ~= nil) then

      -- invdata strips out commas in the names of items.  As a result, we won't find items in
      -- the cache unless we also store them in a form without commas.
      name = string.gsub(name, ",", "")

      local cacheEntry = inv.cache.get(inv.cache.frequent.table, name)
      if (cacheEntry == nil) then

        -- NOTE: Wands and staves may not be completely identical.  The # charges can vary.  Also,
        --       in some game-load cases, they can vary in level.  Nevertheless, the advantages of
        --       treating wands/staves as being identical so that they can be in the frequent cache
        --       outweigh the disadvantages.  If you buy 100 starburst staves, you really don't want
        --       to manually identify each one :p
        itemType = inv.items.getStatField(objId, invStatFieldType)
        if (itemType == invmon.typeStr[invmonTypePotion]) or 
           (itemType == invmon.typeStr[invmonTypePill])   or 
           (itemType == invmon.typeStr[invmonTypeFood])   or 
           (itemType == invmon.typeStr[invmonTypeWand])   or 
           (itemType == invmon.typeStr[invmonTypeStaff])  or 
           (itemType == invmon.typeStr[invmonTypeScroll]) then

          colorName = inv.items.getField(objId, invFieldColorName)
          retval = inv.cache.add(inv.cache.frequent.table, objId)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.warn("inv.items.identifyCR: Failed to add \"" .. (colorName or name or "Unidentified") ..
                      "@W\" to frequent item cache: " .. dbot.retval.getString(retval))
          else
            dbot.note("Added \"" .. (colorName or "Unidentified") .. "@W\" to frequent item cache")
          end -- if
        end -- if
      end -- if
    end -- if

    -- Check if the custom cache has additional details for this item.  For example, we might have
    -- custom keywords or an organize query for the item.
    local cachedEntry = inv.cache.get(inv.cache.custom.table, objId)
    if (cachedEntry ~= nil) then
      -- Merge any cached keywords into the item's keywords field
      if (cachedEntry.keywords ~= nil) and (cachedEntry.keywords ~= "") then
        local oldKeywords = inv.items.getStatField(objId, invStatFieldKeywords) or ""
        local mergedKeywords = dbot.mergeFields(cachedEntry.keywords, oldKeywords) or cachedEntry.keywords
        inv.items.setStatField(objId, invStatFieldKeywords, mergedKeywords)
        dbot.debug("Merged cached keywords = \"" .. mergedKeywords .. "\"")
      end -- if

      -- Use any cached organize queries that exist
      if (cachedEntry.organize ~= nil) and (cachedEntry.organize ~= "") then
        inv.items.setStatField(objId, invQueryKeyOrganize, cachedEntry.organize)
        dbot.debug("Cached organize queries = \"" .. cachedEntry.organize .. "\"")
      end -- if
    end -- if

    -- Save this item incrementally so identification progress survives a crash
    dinv_db.saveItem(objId, inv.items.table[objId])

  end -- for objId,_ in pairs

  -- We are done (at least for now)
  if (retval == DRL_RET_SUCCESS) then
    dbot.debug("Inventory identification procedure completed")
  elseif (retval == DRL_RET_HALTED) then
    dbot.debug("Inventory identification halted early")
  end -- if

  return retval
end -- inv.items.identifyCR


idCommandBasic = "identify"
inv.items.identifyFence = "DINV identify fence"
-- Asynchronous routine to identify an item
function inv.items.identifyItem(objId, idCommand, resultData, commandArray)
  local retval = DRL_RET_SUCCESS
  local command

  assert((objId ~= nil) and (idCommand ~= nil), "inv.items.identifyItem: nil parameters detected")

  local item = inv.items.getEntry(objId)
  if (item == nil) then 
    dbot.warn("inv.items.identifyItem: Failed to identify item " .. objId .. 
              " in inventory table because it is not in the table")
    return DRL_RET_MISSING_ENTRY
  end -- if

  -- Check where the item is (main inventory, worn location, container, etc.).  We will want to
  -- put the item back to its original location once we finish identifying it.
  local objLoc = inv.items.getField(objId, invFieldObjLoc)
  if (objLoc == nil) or (objLoc == invItemLocUninitialized) then
    dbot.debug("inv.items.identifyItem: Failed to identify item " .. objId .. 
               ": item's location could not be determined")
    inv.items.table[objId] = nil
    return DRL_RET_MISSING_ENTRY
  end -- if

  -- Check if another id is in progress before we proceed
  if (inv.items.identifyPkg ~= nil) then
    dbot.info("inv.items.identifyItem: Skipping identification of " .. objId .. 
              ": another identification is in progress")
    return DRL_RET_BUSY
  end -- if

  -- Clear out fields that may be left over from a previous identification.  Otherwise, we may
  -- be left with incorrect values if a temper or envenom added stats to the item previously.
  inv.items.setStatField(objId, invStatFieldStr, 0)
  inv.items.setStatField(objId, invStatFieldInt, 0)
  inv.items.setStatField(objId, invStatFieldWis, 0)
  inv.items.setStatField(objId, invStatFieldDex, 0)
  inv.items.setStatField(objId, invStatFieldCon, 0)
  inv.items.setStatField(objId, invStatFieldLuck, 0)

  -- Use globals to hold state for the identify triggers
  inv.items.identifyPkg         = {}
  inv.items.identifyPkg.objId   = objId
  inv.items.identifyPkg.objLoc  = objLoc
  inv.items.identifyPkg.command = idCommand

  local tmpCommands = {}

  if (commandArray == nil) then
    -- Add a timeout timer to clear the identify request if we take too long.  For example,
    -- we may have tried to identify an item that isn't in our inventory table or we may have
    -- tried to use an invalid identify command.
    check (AddTimer(inv.items.timer.idTimeoutName, 0, 0, inv.items.timer.idTimeoutThresholdSec, "",
                    timer_flag.Enabled + timer_flag.OneShot, "inv.items.timer.idTimeout"))
  end -- if

  -- Identify the item.  If it is in a container, keyring, vault, or worn, we must first put the
  -- item into the main inventory before we ID it.  If we needed to move the item to ID it, put
  -- it back where we got it after the ID completes.

  -- Main inventory
  if (objLoc == invItemLocInventory) then
    command = idCommand .. " " .. objId
    if (commandArray ~= nil) then
      table.insert(commandArray, command)
    else
      table.insert(tmpCommands, command)
      table.insert(tmpCommands, "echo " .. inv.items.identifyFence)
      retval = dbot.execute.safe.commands(tmpCommands, inv.items.identifyItemSetupFn, nil,
                                          dbot.callback.default, resultData)
      if (retval == DRL_RET_SUCCESS) then
        retval = dbot.callback.wait(resultData, 10)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.note("Main inventory identify request did not complete: " .. dbot.retval.getString(retval))
        end -- if
      end -- if
    end -- if

  -- Keyring
  elseif (objLoc == invItemLocKeyring) then
    retval = inv.items.getItem(objId, commandArray)
    if (retval == DRL_RET_SUCCESS) then
      command = idCommand .. " " .. objId
      if (commandArray ~= nil) then
        table.insert(commandArray, command)
      else
        table.insert(tmpCommands, command)
        table.insert(tmpCommands, "echo " .. inv.items.identifyFence)
        retval = dbot.execute.safe.commands(tmpCommands, inv.items.identifyItemSetupFn, nil,
                                            dbot.callback.default, resultData)
        if (retval == DRL_RET_SUCCESS) then
          retval = dbot.callback.wait(resultData, 10)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.note("Keyring identify request did not complete: " .. dbot.retval.getString(retval))
          end -- if
        end -- if
      end -- if

      command = "keyring put " .. objId
      if (commandArray ~= nil) then
        table.insert(commandArray, command)
      else
        local itemName = inv.items.getField(objId, invFieldColorName) or "Unidentified"
        dbot.note("  Putting \"" .. itemName .. "@W" .. DRL_ANSI_WHITE .. "\" onto keyring")

        local resultData2 = dbot.callback.new()
        retval = dbot.execute.safe.command(command, inv.items.putKeyringSetupFn, nil,
                                           inv.items.putKeyringResultFn, resultData2)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.note("Key \"" .. itemName .. "\" was not placed onto keyring: " ..
                    dbot.retval.getString(retval))
        else
          -- Wait until we have confirmation that the callback completed
          retval = dbot.callback.wait(resultData2, 5)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.note("Key \"" .. itemName .. "\" was not placed onto keyring: " ..
                      dbot.retval.getString(retval))
          end -- if
        end -- if
      end -- if
    end -- if

  -- Vault
  elseif (objLoc == invItemLocVault) then
    dbot.error("inv.items.identifyItem: Identifying objects in a vault is not yet supported")
    retval = DRL_RET_UNSUPPORTED

  -- Auction (we may temporarily add an auction item to examine it)
  elseif (objLoc == invItemLocAuction) then
    command = idCommand .. " " .. objId 
    if (commandArray ~= nil) then
      table.insert(commandArray, command)
    else
      table.insert(tmpCommands, command)
      table.insert(tmpCommands, "echo " .. inv.items.identifyFence)
      retval = dbot.execute.safe.commands(tmpCommands, inv.items.identifyItemSetupFn, nil,
                                          dbot.callback.default, resultData)
      if (retval == DRL_RET_SUCCESS) then
        retval = dbot.callback.wait(resultData, 10)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.note("Auction identify request did not complete: " .. dbot.retval.getString(retval))
        end -- if
      end -- if
    end -- if

  -- Shopkeeper (we may temporarily add an item from a shop to examine it)
  elseif (objLoc == invItemLocShopkeeper) then
    if (commandArray ~= nil) then
      table.insert(commandArray, idCommand)
    else
      table.insert(tmpCommands, idCommand)
      table.insert(tmpCommands, "echo " .. inv.items.identifyFence)
      retval = dbot.execute.safe.commands(tmpCommands, inv.items.identifyItemSetupFn, nil,
                                          dbot.callback.default, resultData)
      if (retval == DRL_RET_SUCCESS) then
        retval = dbot.callback.wait(resultData, 10)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.note("Shop identify request did not complete: " .. dbot.retval.getString(retval))
        end -- if
      end -- if
    end -- if

  -- Container
  elseif (type(objLoc) == "number") then

    -- Any objLoc that is a number is a container and the objLoc is the container's ID.
    retval = inv.items.getItem(objId, commandArray)
    if (retval == DRL_RET_SUCCESS) then
      if (inv.items.identifyPkg ~= nil) then
        command = idCommand .. " " .. objId
        if (commandArray ~= nil) then
          table.insert(commandArray, command)
        else
          table.insert(tmpCommands, command)
          table.insert(tmpCommands, "echo " .. inv.items.identifyFence)
          retval = dbot.execute.safe.commands(tmpCommands, inv.items.identifyItemSetupFn, nil,
                                              dbot.callback.default, resultData)
          if (retval == DRL_RET_SUCCESS) then
            retval = dbot.callback.wait(resultData, 10)
            if (retval ~= DRL_RET_SUCCESS) then
              dbot.note("Container identify request did not complete: " .. dbot.retval.getString(retval))
            end -- if
          end -- if
        end -- if
      end -- if

      retval = inv.items.putItem(objId, objLoc, commandArray, false)
    end -- if

  -- Worn
  else
    retval = inv.items.getItem(objId, commandArray)
    if (retval == DRL_RET_SUCCESS) then
      if (inv.items.identifyPkg ~= nil) then
        command = idCommand .. " " .. objId
        if (commandArray ~= nil) then
          table.insert(commandArray, command)
        else
          table.insert(tmpCommands, command)
          table.insert(tmpCommands, "echo " .. inv.items.identifyFence)
          retval = dbot.execute.safe.commands(tmpCommands, inv.items.identifyItemSetupFn, nil,
                                              dbot.callback.default, resultData)
          if (retval == DRL_RET_SUCCESS) then
            retval = dbot.callback.wait(resultData, 10)
            if (retval ~= DRL_RET_SUCCESS) then
              dbot.note("Item identify request did not complete: " .. dbot.retval.getString(retval))
            end -- if
          end -- if
        end -- if
      end -- if
      retval = inv.items.wearItem(objId, objLoc, commandArray, false)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.items.identifyItem: Failed to wear item " .. (objId or "nil") .. ": " ..
                  dbot.retval.getString(retval))
      end -- if
    end -- if

  end -- if

  -- Stop the triggers if something went wrong with the identification
  if (commandArray == nil) then
    if (retval ~= DRL_RET_SUCCESS) then
      inv.items.trigger.itemIdEnd()
    end -- if
  else
    table.insert(commandArray, "echo " .. inv.items.identifyFence)
  end -- if

  return retval
end -- inv.items.identifyItem


function inv.items.identifyItemSetupFn()
  EnableTrigger(inv.items.trigger.suppressWindsName, true)
  EnableTrigger(inv.items.trigger.itemIdStartName,   true)
end -- inv.items.identifyItemSetupFn


function inv.items.identifyAtomicSetup()
  EnableTrigger(inv.items.trigger.wearName,          true)
  EnableTrigger(inv.items.trigger.removeName,        true)
  EnableTrigger(inv.items.trigger.getName,           true)
  EnableTrigger(inv.items.trigger.putName,           true)
  EnableTrigger(inv.items.trigger.getKeyringName,    true)
  EnableTrigger(inv.items.trigger.putKeyringName,    true)
  EnableTrigger(inv.items.trigger.wearSpecialName,   true)
  EnableTrigger(inv.items.trigger.itemIdStartName,   true)
  EnableTrigger(inv.items.trigger.suppressWindsName, true)
end -- inv.items.identifyAtomicSetup


function inv.items.identifyAtomicCleanup(resultData, retval)
  EnableTrigger(inv.items.trigger.wearName,        false)
  EnableTrigger(inv.items.trigger.removeName,      false)
  EnableTrigger(inv.items.trigger.getName,         false)
  EnableTrigger(inv.items.trigger.putName,         false)
  EnableTrigger(inv.items.trigger.getKeyringName,  false)
  EnableTrigger(inv.items.trigger.putKeyringName,  false)
  EnableTrigger(inv.items.trigger.wearSpecialName, false)

  inv.items.trigger.itemIdEnd() -- clears itemIdStartName and others...

  dbot.callback.default(resultData, retval)
end -- inv.items.identifyAtomicCleanup


invStateIdle    = "idle"
invStateRunning = "running"
invStatePaused  = "paused"
invStateHalted  = "halted"

inv.items.refreshPkg = nil
inv.items.fullScanCompleted = false
function inv.items.refresh(maxNumItems, refreshLocations, endTag, tagProxy)

  local retval = DRL_RET_SUCCESS
  local tagModule = invTagsRefresh

  if (tagProxy ~= nil) and (tagProxy ~= "") then
    tagModule = tagProxy
  end -- if

  dbot.debug("inv.items.refresh: #items=" .. (maxNumItems or "nil") .. ", locs=\"" ..
             (refreshLocations or "nil") .. "\"")

  if (dbot.gmcp.isInitialized == false) then
    dbot.info("Skipping refresh request: GMCP is not yet initialized")
    return inv.tags.stop(tagModule, endTag, DRL_RET_UNINITIALIZED)
  end -- if

  local charState = dbot.gmcp.getState()

  -- We want a user to run the build operation at least once before we allow
  -- the normal refresh to occur.  We don't necessarily even need to complete
  -- the build.  The main concern is that we don't want an auto-refresh to
  -- clog up the system for several minutes without warning the first time the
  -- user enables this plugin.
  if (inv.config.table.isBuildExecuted == false) then
    dbot.print(
[[@W
  You must perform at least one manual inventory build before we allow inventory refresh
  requests to proceed.  Otherwise, a user's first automatic refresh could clog up the system
  for several minutes as the entire inventory is scanned.  We don't want the user to be 
  surprised by that behavior.
]]) 
    dbot.print("@W  Please see \"@G" .. pluginNameCmd .. " help build@W\" for more details.")
    dbot.print("@W\nUsage:")
    inv.cli.build.usage()
    dbot.print("")
    retval = DRL_RET_UNINITIALIZED

  -- If refreshes are enabled (period > 0) but are paused (state == invStatePaused) we skip
  -- the refresh now but we still schedule the next one
  elseif (inv.state == invStatePaused) then
    dbot.debug("Skipping refresh request: automatic refreshes are paused")
    retval = DRL_RET_BUSY

  -- If another refresh is in progress, try again later
  elseif (inv.state == invStateRunning) then
    dbot.note("Skipping refresh request: another refresh is in progress")
    retval = DRL_RET_BUSY

  elseif (inv.state == invStateHalted) then
    dbot.info("Skipping refresh request: plugin is halted")
    retval = DRL_RET_UNINITIALIZED

  -- If we aren't in the "active" character state (sleeping, running, AFK, writing a note, etc.)
  -- then we wait a bit and try again
  elseif (charState ~= dbot.stateActive) then
    dbot.debug("Skipping refresh request: char is in state \"" .. dbot.gmcp.getStateString(charState) .. "\"")
    retval = DRL_RET_NOT_ACTIVE    

  -- If the char is in the active state (e.g., not AFK, in a note, in combat, etc.) refresh now
  -- and schedule the next refresh after the default period
  else
    inv.state = invStateRunning
    inv.items.refreshPkg                  = {}
    inv.items.refreshPkg.maxNumItems      = maxNumItems
    inv.items.refreshPkg.refreshLocations = refreshLocations
    inv.items.refreshPkg.endTag           = endTag
    inv.items.refreshPkg.tagModule        = tagModule

    -- If we haven't performed a full scan yet since we initialized the plugin, make this a
    -- full scan.  We want to run at least one full scan so that we handle orphan equipment
    -- and detect if the user moved stuff around in another client or in this client when the
    -- plugin was disabled.
    if (not inv.items.fullScanCompleted) then
      inv.items.refreshPkg.refreshLocations = invItemsRefreshLocAll
    end -- if

    wait.make(inv.items.refreshCR)
    retval = DRL_RET_SUCCESS
  end -- if

  -- Schedule the next refresh if automatic refreshes are enabled (i.e., the period is > 0 minutes)
  local refreshMin = inv.items.refreshGetPeriods() or 0
  if (refreshMin > 0) and (inv.state ~= nil) then
    dbot.debug("Scheduling automatic inventory refresh in " .. refreshMin .. " minutes")
    inv.items.refreshAtTime(refreshMin, 0)
  end -- if

  -- If everything went as planned, we have a co-routine doing a refresh and that co-routine will 
  -- terminate any end tags that were specified.  Otherwise, we hit an error and we should terminate
  -- the tag now and return what we know to the caller.
  if (retval == DRL_RET_SUCCESS) then
    return retval
  else
    return inv.tags.stop(tagModule, endTag, retval)
  end -- if
end -- inv.items.refresh


function inv.items.refreshCR()
  local retval = DRL_RET_SUCCESS

  -- We can skip the refresh if we've already done a full scan, there are no known "dirty" 
  -- locations or containers, and the user didn't explicitly request a full scan
  if inv.items.fullScanCompleted and
     (inv.items.refreshPkg.refreshLocations ~= invItemsRefreshLocAll) and
     (not inv.items.isDirty()) then
    dbot.debug("Skipping refresh because there are no known unidentified items")
    inv.state = invStateIdle
    return inv.tags.stop(inv.items.refreshPkg.tagModule, inv.items.refreshPkg.endTag, retval)
  end -- if

  dbot.note("Refreshing inventory: START")

  -- Disable the prompt to avoid confusing output during the refresh
  dbot.prompt.hide()

  -- On each refresh request we track all items discovered and match that against the contents
  -- of the inventory table.  If something is in the inventory table and we didn't find it 
  -- during refresh, remove it from the inventory table because the table is out of sync.
  inv.items.currentItems = {}

  -- Discover and identify new inventory items.  Both co-routines are blocking.
  retval = inv.items.discoverCR(inv.items.refreshPkg.maxNumItems, inv.items.refreshPkg.refreshLocations)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("Skipping item discovery: " .. dbot.retval.getString(retval))
  else -- discovery passed :)
    -- Identify everything we just discovered
    retval = inv.items.identifyCR(inv.items.refreshPkg.maxNumItems, inv.items.refreshPkg.refreshLocations)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.debug("Skipping item identification: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  -- Remove any items that are in the inventory table that were not discovered during this
  -- refresh.  It's possible that things are out of sync (e.g., the table wasn't saved after
  -- a change to the inventory).  Of course, if the user halted the current search then we
  -- may not have found items that actually are present so we only remove orphans if we
  -- fully completed the discovery and identification steps above.  Also, if we are only 
  -- scanning some locations, then we don't want to remove orphans because the items could
  -- be at a location we didn't scan this time.
  if (retval == DRL_RET_SUCCESS) and (inv.items.refreshPkg.refreshLocations == invItemsRefreshLocAll) then
    for k,v in pairs(inv.items.table) do
      if (inv.items.currentItems[k] == nil) then
        dbot.note("Removed orphan: \"" .. (inv.items.getField(k, invFieldColorName) or "Unidentified") .. 
                  DRL_ANSI_WHITE .. "\" (" .. k .. ")")
        inv.items.table[k] = nil
      end -- if
    end -- for
  end -- if

  inv.items.currentItems = nil

  -- Re-enable the prompt
  dbot.prompt.show()

  -- Save everything we just discovered and identified.  Items get a wholesale
  -- rewrite (which also implicitly cleans up the disk rows for the orphans
  -- pruned above and catches any itemDataStats field updates on already-
  -- identified items that didn't go through identifyCR's per-item save).
  -- inv.config doesn't need a save here -- the only config mutation that
  -- ever flows through this path is inv.items.build's isBuildExecuted flag,
  -- which is now persisted at its mutation site instead.
  inv.items.save()

  if (retval == DRL_RET_SUCCESS) then
    resultString = "SUCCESS! (Entire inventory is identified)"
  elseif (retval == DRL_RET_HALTED) then
    resultString = "HALTED! (Some items may still need identification)"
  elseif (retval == DRL_RET_IN_COMBAT) then
    resultString = "IN COMBAT! (Skipped identification because you were fighting!)"
  elseif (retval == DRL_RET_TIMEOUT) then
    resultString = "TIMEOUT! (Skipped identification because you were busy)"
  elseif (retval == DRL_RET_NOT_ACTIVE) then
    resultString = "NOT ACTIVE! (You were not ready for item identification)"
  elseif (retval == DRL_RET_UNINITIALIZED) then
    resultString = "UNINITIALIZED! (The plugin is not initialized)"
  else
    resultString = "ERROR! (" .. dbot.retval.getString(retval) .. ")"
  end -- if

  dbot.note("Refreshing inventory: " .. resultString)

  inv.state = invStateIdle

  -- We want at least one full scan after the plugin loads.  If we've successfully completed a full
  -- scan, remember it so that we don't need to do it again until the plugin reloads.
  if (inv.items.refreshPkg.refreshLocations == invItemsRefreshLocAll) then
    if (retval == DRL_RET_SUCCESS) then
      inv.items.fullScanCompleted = true
    end -- if

    dbot.debug("Inventory refresh full scan: " .. dbot.retval.getString(retval))
  end -- if

  return inv.tags.stop(inv.items.refreshPkg.tagModule, inv.items.refreshPkg.endTag, retval)

end -- inv.items.refreshCR


-- Kick the refresh timer to start at a time "min" minutes and "sec" seconds from the time this is called
function inv.items.refreshAtTime(min, sec)
  if (min == nil) or (sec == nil) then
    dbot.warn("inv.items.refreshAtTime: nil time given as parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  min = tonumber(min) or 0
  sec = tonumber(sec) or 0

  if (min == 0) and (sec == 0) then
    dbot.warn("inv.items.refreshAtTime: invalid time period 0 detected")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- It's possible (but highly unlikely) that we timed out and disconnected from the mud causing
  -- us to de-init our modules at the exact instant we schedule the next refresh.  If that happens
  -- then our state will be nil and we shouldn't continue with the refresh.
  if (inv.state == nil) then
    dbot.warn("inv.items.refreshAtTime: inventory module is not initialized")
    return DRL_RET_UNINITIALIZED
  end -- if

  -- We can't add the timer directly because we are in the function called by that timer.  Instead,
  -- we use an intermediate timer to call back and start this timer again.  Yeah, it's a bit ugly...
  DoAfterSpecial(0.1, -- start up in 100 ms
                 string.format("AddTimer(%s, 0, %d, %d, \"\", %d, " ..
                               "\"inv.items.refreshDefault\")",
                               "inv.items.timer.refreshName", min, sec,
                               timer_flag.Enabled + timer_flag.Replace + timer_flag.OneShot),
                 sendto.script)

  return DRL_RET_SUCCESS
end -- inv.items.refreshAtTime


function inv.items.refreshDefault()
  local retval = DRL_RET_SUCCESS

  if (inv.state == nil) then
    dbot.warn("inv.items.refreshDefault: inventory module is not initialized")
    return DRL_RET_UNINITIALIZED
  end -- if

  -- By default, refresh only dirty locations and skip item locations that don't contain any
  -- unidentified items.
  if (inv.items.refreshGetPeriods() > 0) then
    retval = inv.items.refresh(0, invItemsRefreshLocDirty, nil, nil)
  end -- if

  return retval
end -- inv.items.refreshDefault


function inv.items.refreshGetPeriods()
  return inv.config.table.refreshPeriod, inv.config.table.refreshEagerSec
end -- inv.items.refreshGetPeriods


function inv.items.refreshSetPeriods(autoMin, eagerSec)
  inv.config.table.refreshPeriod = tonumber(autoMin) or inv.items.timer.refreshMin
  inv.config.table.refreshEagerSec = tonumber(eagerSec) or inv.items.timer.refreshEagerSec

  return inv.config.save()
end -- inv.items.refreshSetPeriods


function inv.items.refreshOn(autoMin, eagerSec)
  autoMin = tonumber(autoMin or "") or inv.items.timer.refreshMin
  if (autoMin < 1) then
    dbot.warn("inv.items.refreshOn: Automatic refreshes must have a period of at least one minute")
    return DRL_RET_INVALID_PARAM
  end -- if

  inv.items.refreshSetPeriods(autoMin, eagerSec or 0)

  inv.state = invStateIdle

  -- Schedule the next refresh
  return inv.items.refreshAtTime(autoMin, 0)
end -- inv.items.refreshOn


function inv.items.refreshOff()
  inv.state = invStatePaused
  dbot.deleteTimer(inv.items.timer.refreshName)
  return inv.items.refreshSetPeriods(0, 0)
end -- inv.items.refreshOff


-- This checks all locations and determines if there are any known unidentified items.  If there
-- is at least one unidentified item, isDirty() returns true.  Otherwise, it returns false.
function inv.items.isDirty()
  local isDirty = false

  -- Check the easy locations first.  If something unidentified is worn, on your keyring, or in
  -- your main inventory, return true.  We don't even need to look at containers.
  if (inv.items.wornState    == invItemsRefreshDirty) or
     (inv.items.mainState    == invItemsRefreshDirty) or
     (inv.items.keyringState == invItemsRefreshDirty) then
    isDirty = true

  -- Check containers to see if any are "dirty" and hold at least one unidentified item
  else
    -- For every item in your inventory, check if it's a container.  If it is a container we must
    -- next check if it has the "clean" keyword indicating that it hasn't had any unidentified
    -- items added to it since its last scan.  If it's not "clean", then it's "dirty".
    for objId,_ in pairs(inv.items.table) do
      if (inv.items.getStatField(objId, invStatFieldType) == invmon.typeStr[invmonTypeContainer]) then
        local keywordField = inv.items.getStatField(objId, invStatFieldKeywords) or ""
        if (not dbot.isWordInString(invItemsRefreshClean, keywordField)) then
          isDirty = true
          break
        end -- if
      end -- if
    end -- for
  end -- if

  return isDirty
end -- inv.items.isDirty


function inv.items.build(endTag)
  local retval

  retval = inv.items.reset()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.build: inventory reset failed: " .. dbot.retval.getString(retval))
    return inv.tags.stop(invTagsBuild, endTag, retval)
  end -- if

  retval = inv.config.reset()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.build: configuration reset failed: " .. dbot.retval.getString(retval))
    return inv.tags.stop(invTagsBuild, endTag, retval)
  end -- if

  retval = inv.cache.reset()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.build: reset of all caches failed: " .. dbot.retval.getString(retval))
    return inv.tags.stop(invTagsBuild, endTag, retval)
  end -- if

  inv.config.table.isBuildExecuted = true
  inv.state = invStateIdle

  -- Persist the just-set isBuildExecuted flag here at its mutation site so
  -- inv.items.refreshCR doesn't have to issue a save on every refresh just
  -- to cover this one build-time write.
  inv.config.save()

  -- The call to refresh is a little unusual in that we pass the build endTag to the refresh
  -- code.  When the refresh code completes, it will output the endTag it received from build
  -- instead of the normal refresh endTag.  We do this to avoid the need to spin here and wait
  -- for refresh to complete before we output the build endTag indicating the build is done.
  retval = inv.items.refresh(0, invItemsRefreshLocAll, endTag, invTagsBuild)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.build: refresh did not complete: " .. dbot.retval.getString(retval))
  end -- if  

  return retval

end -- inv.items.build()


----------------------------------------------------------------------------------------------------
-- inv.items.get(query, endTag)  -- non-blocking, kicks off blocking inv.items.getCR asynchronously
-- inv.items.getCR()  -- blocks until commands to move all matching items are queued, executed, and confirmed
-- inv.items.getItem(itemId) -- blocks until the command to get the item is queued, executed, and confirmed
--
-- inv.items.getSetupFn()
-- inv.items.getResultFn(resultData, retval)
--
-- inv.items.getKeyringSetupFn()
-- inv.items.getKeyringResultFn(resultData, retval)
--
-- Move item(s) to main inventory
--
-- Suppress get verbage: 
--   "You remove ..."                 -- remove item
--   "You stop wielding ..."          -- remove weapon
--   "You stop using ..."             -- remove portal
--   "... stops floating around you." -- remove float
--   "... stops floating above you."  -- remove aura of trivia
--   "You are not wearing that item." -- remove BADNAME
--   "You get ... from ..."           -- get item container
--   "You do not see that in ..."     -- get BADNAME container
----------------------------------------------------------------------------------------------------

inv.items.getPkg = nil
function inv.items.get(queryString, endTag)
  if (queryString == nil) then
    dbot.warn("inv.items.get: query is nil")
    return inv.tags.stop(invTagsGet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.items.getPkg ~= nil) then
    dbot.info("Skipping get request for query \"" .. queryString .. "\", another get request is in progress")
    return inv.tags.stop(invTagsGet, endTag, DRL_RET_BUSY)
  end -- if

  -- We use a background co-routine to perform the "get".  The co-routine can schedule
  -- itself and block until the get completes.
  inv.items.getPkg             = {}
  inv.items.getPkg.queryString = queryString or ""
  inv.items.getPkg.endTag      = endTag

  wait.make(inv.items.getCR)

  return DRL_RET_SUCCESS
end -- inv.items.get


function inv.items.getCR()
  local retval = DRL_RET_SUCCESS
  local idArray

  -- Be paranoid!
  if (inv.items.getPkg == nil) or (inv.items.getPkg.queryString == nil) then
    dbot.error("inv.items.getCR: Aborting get request -- get package or query is nil!")
    inv.items.getPkg = nil
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local endTag = inv.items.getPkg.endTag

  -- Get an array of object IDs that match the get request's query string
  idArray, retval = inv.items.searchCR(inv.items.getPkg.queryString)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.getCR: failed to search inventory table: " .. dbot.retval.getString(retval))

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    dbot.info("No match found for get query: \"" .. inv.items.getPkg.queryString .. "\"")
    retval = DRL_RET_MISSING_ENTRY

  -- We found items to move!
  else
    local commandArray = dbot.execute.new()
    local numItemsMoved = 0
    for _,id in ipairs(idArray) do
      retval = inv.items.getItem(id, commandArray)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.debug("Skipping request to get item " .. id .. ": " .. dbot.retval.getString(retval))
        break
      else
        numItemsMoved = numItemsMoved + 1
      end -- if

      if (commandArray ~= nil) and (#commandArray >= inv.items.burstSize) then
        retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.info("Skipping request to get items: " .. dbot.retval.getString(retval))
          break
        end -- if
        commandArray = dbot.execute.new()
      end -- if

    end -- for

    -- Flush any commands in the array that still need to be sent to the mud
    if (retval == DRL_RET_SUCCESS) and (commandArray ~= nil) then
      retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.info("Skipping request to get items: " .. dbot.retval.getString(retval))
      end -- if
    end -- if

    if (retval == DRL_RET_SUCCESS) then
      dbot.info("Get request matched " .. numItemsMoved .. " items")
    end -- if

  end -- if


  inv.items.getPkg = nil

  return inv.tags.stop(invTagsGet, endTag, retval)
end -- inv.items.getCR


function inv.items.getItem(objId, commandArray)
  local retval = DRL_RET_SUCCESS

  if (objId == nil) or (type(objId) ~= "number") then
    dbot.warn("inv.items.getItem: Non-numeric objId parameter detected")
    return DRL_RET_INVALID_PARAM
  end -- if

  local itemLoc = inv.items.getField(objId, invFieldObjLoc)

  local itemName = inv.items.getField(objId, invFieldColorName) or "Unidentified"
  itemName = itemName .. "@W" .. DRL_ANSI_WHITE

  if (commandArray == nil) then
    dbot.prompt.hide()
  end -- if

  if (itemLoc == nil) then
    dbot.debug("inv.items.getItem: item location for objId " .. objId .. " is missing")
    retval = DRL_RET_MISSING_ENTRY
  else
    local itemLocNum = tonumber(itemLoc)

    -- If the location is a number, it is a container's ID
    if (itemLocNum ~= nil) then
      local containerName = (inv.items.getField(itemLocNum, invFieldColorName) or "Unidentified") ..
                            "@W" .. DRL_ANSI_WHITE
      local containerLoc

      -- It's possible that the container is a worn item.  If that is the case, we must first
      -- remove the container before we can get something out of it.
      if (inv.items.isWorn(itemLocNum)) then
        containerLoc = inv.items.getField(itemLocNum, invFieldObjLoc) or ""
        retval = inv.items.removeItem(itemLocNum, commandArray)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.items.getItem: Failed to remove container \"" .. containerName .. "\"")
        end -- if
      end -- if

      local getCommand = "get " .. objId .. " " .. itemLocNum
      if (commandArray ~= nil) then
        table.insert(commandArray, getCommand)
      else
        dbot.note("  Getting \"" .. itemName .. "\" from \"" .. containerName .. "\"")

        -- Get the item and wait for confirmation that it moved
        local resultData = dbot.callback.new()
        retval = dbot.execute.safe.command(getCommand, inv.items.getSetupFn, nil,
                                           inv.items.getResultFn, resultData)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.note("Skipping request to get \"" .. itemName .. "\": " .. dbot.retval.getString(retval))
        else
          -- Wait until we have confirmation that the callback completed
          retval = dbot.callback.wait(resultData, 5)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.note("Skipping request to get \"" .. itemName .. "\": " .. dbot.retval.getString(retval))
          end -- if
        end -- if

        -- Verify that the item is now in the main inventory.  It may take a moment or two for invmon
        -- to realize we moved the item.  We spin a bit here to give invmon the chance to update the
        -- item's location.
        local totTime = 0
        local timeout = 1
        while (invItemLocInventory ~= inv.items.getField(objId, invFieldObjLoc)) do
          if (totTime > timeout) then
            if inv.items.isInvis(objId) then
              dbot.info("Failed to get invisible item \"" .. itemName .. "\" from container \"" ..
                        containerName .. "\": can you detect invis?")
            elseif inv.items.isInvis(itemLocNum) then
              dbot.info("Failed to get \"" .. itemName .. "\" from invisible container \"" ..
                        containerName .. "\": can you detect invis?")
            else
              dbot.warn("inv.items.getItem: Timed out before invmon confirmed item is in target container")
            end -- if
            retval = DRL_RET_MISSING_ENTRY
            break
          end -- if

          wait.time(drlSpinnerPeriodDefault)
          totTime = totTime + drlSpinnerPeriodDefault
        end -- while
      end -- if

      -- If we pulled the item out of a worn container, we must remember to re-wear the container
      -- now that we took the item out of it
      if (containerLoc ~= nil) then 
        local containerRetval = inv.items.wearItem(itemLocNum, nil, commandArray, false)
        if (containerRetval ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.items.getItem: Failed to wear item " .. (objId or "nil") .. ": " ..
                    dbot.retval.getString(containerRetval))

          -- If we haven't hit another error yet, store the current error code
          if (retval == DRL_RET_SUCCESS) then
            retval = containerRetval
          end -- if
        end -- if
      end -- if

    elseif (itemLoc == invItemLocInventory) then
      dbot.debug("Item \"" .. itemName .. "\" is already in your main inventory")

    elseif (itemLoc == invItemLocKeyring) then
      local getCommand = "keyring get " .. objId
      if (commandArray ~= nil) then
        table.insert(commandArray, getCommand)
      else
        dbot.note("  Getting \"" .. itemName .. "\" from keyring")

        local resultData = dbot.callback.new()
        retval = dbot.execute.safe.command(getCommand, inv.items.getKeyringSetupFn, nil,
                                           inv.items.getKeyringResultFn, resultData)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.items.getItem: Failed to get keyring item: " .. dbot.retval.getString(retval))
        else
          -- Wait until we have confirmation that the callback completed
          retval = dbot.callback.wait(resultData, 5)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.note("Skipping request to get key \"" .. itemName .. "\" from keyring: " ..
                      dbot.retval.getString(retval))
          end -- if
        end -- if
      end -- if

    elseif (itemLoc == invItemLocUninitialized) or
           (itemLoc == invItemLocWorn)          or
           (itemLoc == invItemLocVault)         then
      dbot.error("inv.items.getItem: We do not yet support uninitialized items or getting items from a vault")
      retval = DRL_RET_UNSUPPORTED

    -- The location is a string representing a wearable location
    else
      dbot.debug("Removing item \"" .. itemName .. "\" worn at location " .. itemLoc)

      -- Remove the item and wait for confirmation that it moved
      retval = inv.items.removeItem(objId, commandArray)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.debug("Skipping removal of \"" .. itemName .. "\" worn at location " .. 
                   itemLoc .. ": " .. dbot.retval.getString(retval))
      end -- if
    end -- if

  end -- if

  if (commandArray == nil) then
    dbot.prompt.show()
  end -- if

  return retval
end -- inv.items.getItem


function inv.items.getSetupFn()
  EnableTrigger(inv.items.trigger.getName, true)
end -- inv.items.getSetupFn


function inv.items.getResultFn(resultData, retval)
  EnableTrigger(inv.items.trigger.getName, false)
  dbot.callback.default(resultData, retval)
end -- inv.items.getResultFn


function inv.items.getKeyringSetupFn()
  EnableTrigger(inv.items.trigger.getKeyringName, true)
end -- inv.items.getKeyringSetupFn


function inv.items.getKeyringResultFn(resultData, retval)
  EnableTrigger(inv.items.trigger.getKeyringName, false)
  dbot.callback.default(resultData, retval)
end -- inv.items.getKeyringResultFn


----------------------------------------------------------------------------------------------------
-- inv.items.put(container, query, endTag) -- non-blocking, kicks off blocking inv.items.putCR asynchronously
-- inv.items.putCR()                       -- blocks until all items are confirmed to be moved
-- inv.items.putItem(objId, containerId, commandArray, doCheckLocation) -- blocks until the put is done
--
-- inv.items.putSetupFn()
-- inv.items.putResultFn(resultData)
--
-- inv.items.putKeyringSetupFn()
-- inv.items.putKeyringResultFn(resultData)

-- Move item(s) to container
--
-- Suppress put verbage:
--   "You don't have that."           -- put BADNAME container
--   "You do not see a[n] ... here."  -- put item BADNAME
--   "You put ... into ..."           -- put item bag
----------------------------------------------------------------------------------------------------

inv.items.putPkg = nil
function inv.items.put(container, queryString, endTag)

  if (container == nil) or (container == "") then
    dbot.warn("inv.items.put: missing container parameter")
    return inv.tags.stop(invTagsPut, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (queryString == nil) then
    dbot.warn("inv.items.put: query is nil")
    return inv.tags.stop(invTagsPut, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.items.putPkg ~= nil) then
    dbot.info("Skipping put request for query \"" .. queryString .. "\", another put request is in progress")
    return inv.tags.stop(invTagsPut, endTag, DRL_RET_BUSY)
  end -- if

  -- We use a background co-routine to perform the "put".  The co-routine can schedule
  -- itself and block until the put completes.
  inv.items.putPkg             = {}
  inv.items.putPkg.container   = container
  inv.items.putPkg.queryString = queryString or ""
  inv.items.putPkg.endTag      = endTag

  wait.make(inv.items.putCR)

  return DRL_RET_SUCCESS
end -- inv.items.put


function inv.items.putCR()
  local retval = DRL_RET_SUCCESS
  local idArray
  local containerId

  -- Be paranoid!
  if (inv.items.putPkg == nil) or (inv.items.putPkg.container == nil) or 
     (inv.items.putPkg.queryString == nil) then
    dbot.error("inv.items.putCR: Aborting put request -- put package, container or query is nil!")
    inv.items.putPkg = nil
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local endTag = inv.items.putPkg.endTag

  -- Determine the object ID for the target container.  If the container parameter is a number
  -- then we treat it as the container's object ID.  Otherwise, we treat it as a relative name
  -- (e.g., "3.bag") and find the container's object ID based on the relative name.
  containerId = tonumber(inv.items.putPkg.container)
  if (containerId == nil) then
    _, containerId, retval = inv.items.convertRelative(invQueryKeyRelativeName, inv.items.putPkg.container)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.items.putCR: Failed to convert relative name \"" .. inv.items.putPkg.container ..
                "\" to object ID: " .. dbot.retval.getString(retval))
      inv.items.putPkg = nil
      return inv.tags.stop(invTagsPut, endTag, retval)
    end -- if

    containerId = tonumber(containerId)
    if (containerId == nil) then
      dbot.warn("inv.items.putCR: Container \"" .. inv.items.putPkg.container .. 
                "\" resolved to a non-numeric object ID -- aborting put request")
      inv.items.putPkg = nil
      return inv.tags.stop(invTagsPut, endTag, DRL_RET_INTERNAL_ERROR)
    end -- if
  end -- if

  local containerName = (inv.items.getField(containerId, invFieldColorName) or "Unidentified") ..
                        "@W" .. DRL_ANSI_WHITE

  -- Get an array of object IDs that match the put request's query string
  idArray, retval = inv.items.searchCR(inv.items.putPkg.queryString)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.putCR: failed to search inventory table: " .. dbot.retval.getString(retval))

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    dbot.info("No match found for put query: \"" .. inv.items.putPkg.queryString .. "\"")
    retval = DRL_RET_MISSING_ENTRY

  -- We found items to move!
  else
    local commandArray = dbot.execute.new()
    local numItemsMoved = 0

    for _,objId in ipairs(idArray) do
      retval = inv.items.putItem(objId, containerId, commandArray, true)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.debug("Skipping request to put item " .. objId .. " in container \"" .. 
                   containerName .. "\" (" .. containerId .. "): " .. dbot.retval.getString(retval))
        break
      else
        numItemsMoved = numItemsMoved + 1
      end -- if

      if (commandArray ~= nil) then
        if (#commandArray >= inv.items.burstSize) then
          retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.info("Skipping request to put items: " .. dbot.retval.getString(retval))
            break
          end -- if
          commandArray = dbot.execute.new()
        end -- if
      end -- if
    end -- for

    -- Flush any commands in the array that still need to be sent to the mud
    if (retval == DRL_RET_SUCCESS) and (commandArray ~= nil) then
      retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.info("Skipping request to get items: " .. dbot.retval.getString(retval))
      end -- if
    end -- if

    if (retval == DRL_RET_SUCCESS) then
      dbot.info("Put request matched " .. numItemsMoved .. " items")
    end -- if

  end -- if

  inv.items.putPkg = nil

  return inv.tags.stop(invTagsPut, endTag, retval)
end -- inv.items.putCR


function inv.items.putItem(objId, containerId, commandArray, doCheckLocation)
  local retval = DRL_RET_SUCCESS

  -- Parameter paranoia isn't necessarily a bad thing...
  if (objId == nil) or (type(objId) ~= "number") then
    dbot.warn("inv.items.putItem: Non-numeric objId parameter detected")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (containerId == nil) or (type(containerId) ~= "number") then
    dbot.warn("inv.items.putItem: Non-numeric containerId parameter detected")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- Get the name of the target items.  This is convenient for debug, warning, and error messages.
  local itemName = (inv.items.getField(objId, invFieldColorName) or "Unidentified") ..
                   "@W" .. DRL_ANSI_WHITE

  -- The target container may not be in our inventory (it might be on the floor or might
  -- be furniture in a room).  
  local containerName = (inv.items.getField(containerId, invFieldColorName) or "Room container") ..
                        "@W" .. DRL_ANSI_WHITE
  local isRoomContainer = false
  if (inv.items.getEntry(containerId) == nil) then
    isRoomContainer = true
  end -- if
  local containerLoc

  -- If the item is not already in our main inventory, get it and put it in the main inventory
  local itemLoc = inv.items.getField(objId, invFieldObjLoc)
  if (itemLoc == nil) then
    dbot.error("inv.items.putItem: item location for objId " .. objId .. " is missing")
    return DRL_RET_INTERNAL_ERROR

  elseif (itemLoc == containerId) then
    if (commandArray == nil) or doCheckLocation then
      dbot.note("Item \"" .. itemName .. "\" is already in container \"" .. containerName .. "\"")
      return DRL_RET_SUCCESS
    else
      if (inv.items.isWorn(containerId)) then
        containerLoc = inv.items.getField(containerId, invFieldObjLoc) or ""
        table.insert(commandArray, "remove " .. containerId)
      end -- if

      table.insert(commandArray, "get " .. objId .. " " .. containerId)
    end -- if

  elseif (itemLoc ~= invItemLocInventory) then
    -- It's possible that the container is a worn item.  If that is the case, we must first
    -- remove the container before we can put something into it.
    if (inv.items.isWorn(containerId)) then
      containerLoc = inv.items.getField(containerId, invFieldObjLoc) or ""
      retval = inv.items.removeItem(containerId, commandArray)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.note("Skipping request to remove worn container \"" .. containerName ..
                  "\": " .. dbot.retval.getString(retval))
      end -- if
    end -- if

    retval = inv.items.getItem(objId, commandArray)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.note("Skipping request to move item " .. objId .. " to main inventory: " .. 
                dbot.retval.getString(retval))
      return retval
    end -- if
  end -- if

  local putCommand = "put " .. objId .. " " .. containerId
  if (commandArray ~= nil) then
    table.insert(commandArray, putCommand)
  else
    -- We have the item and we know the containerId that should hold the item.  Move it and wait
    -- for confirmation that the move completed.
    dbot.note("  Putting \"" .. itemName .. "\" into \"" .. containerName .. "\"")
    dbot.prompt.hide()

    local resultData = dbot.callback.new()
    retval = dbot.execute.safe.command(putCommand, inv.items.putSetupFn, nil,
                                       inv.items.putResultFn, resultData)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.note("Skipping request to put \"" .. itemName .. "\": " .. dbot.retval.getString(retval))
    else
      -- Wait until we have confirmation that the callback completed
      retval = dbot.callback.wait(resultData, 5)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.note("Skipping request to put \"" .. itemName .. "\": " .. dbot.retval.getString(retval))
      end -- if
    end -- if

    -- Confirm that the item is now in the target container (unless we aren't holding the container)
    if (retval == DRL_RET_SUCCESS) and (isRoomContainer == false) then
      local totTime = 0
      local timeout = 1
      while (containerId ~= inv.items.getField(objId, invFieldObjLoc)) do
        if (totTime > timeout) then
          if inv.items.isInvis(objId) then
            dbot.info("Failed to put invisible item \"" .. itemName .. "\" into container \"" ..
                      containerName .. "\": can you detect invis?")
          elseif inv.items.isInvis(containerId) then
            dbot.info("Failed to put \"" .. itemName .. "\" into invisible container \"" ..
                      containerName .. "\": can you detect invis?")
          else
            dbot.warn("inv.items.putItem: Timed out before invmon confirmed item is in target container")
          end -- if
          retval = DRL_RET_TIMEOUT
          break
        end -- if

        wait.time(drlSpinnerPeriodDefault)
        totTime = totTime + drlSpinnerPeriodDefault
      end -- while
    end -- if

    dbot.prompt.show()
  end -- if

  -- If we put the item into a worn container, we must remember to re-wear the container
  if (containerLoc ~= nil) then
    retval = inv.items.wearItem(containerId, nil, commandArray, doCheckLocation)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.items.putItem: Failed to wear container " .. (containerId or "nil") .. ": " ..
                dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- inv.items.putItem


function inv.items.putSetupFn()
  EnableTrigger(inv.items.trigger.putName, true)
end -- inv.items.putSetupFn


function inv.items.putResultFn(resultData, retval)
  EnableTrigger(inv.items.trigger.putName, false)
  dbot.callback.default(resultData, retval)
end -- inv.items.putResultFn


function inv.items.putKeyringSetupFn()
  EnableTrigger(inv.items.trigger.putKeyringName, true)
end -- inv.items.putKeyringSetupFn


function inv.items.putKeyringResultFn(resultData, retval)
  EnableTrigger(inv.items.trigger.putKeyringName, false)
  dbot.callback.default(resultData, retval)
end -- inv.items.putKeyringResultFn


----------------------------------------------------------------------------------------------------
-- inv.items.store(query, endTag) -- non-blocking, kicks off blocking inv.items.putCR asynchronously
-- inv.items.storeCR()            -- blocks until all items are confirmed to be moved
-- inv.items.storeItem(itemId)    -- blocks until the store commands are executed and confirmed
--
-- Move each item that matches the query string into the item's "home" container.  An item's
-- home container is the most recent container to hold the item.  Tracking this lets us wear
-- an item (maybe as part of a set) and then "store" the item back where we got it automagically.
-- You can change an item's home container simply by moving it to a different container.  Easy!
----------------------------------------------------------------------------------------------------

inv.items.storePkg = nil
function inv.items.store(queryString, endTag)

  if (queryString == nil) then
    dbot.warn("inv.items.store: query is nil")
    inv.tags.stop(invTagsStore, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.items.storePkg ~= nil) then
    dbot.info("Skipping store request for query \"" .. queryString .. 
              "\", another store request is in progress")
    inv.tags.stop(invTagsStore, endTag, DRL_RET_BUSY)
  end -- if

  -- We use a background co-routine to perform the "store".  The co-routine can schedule
  -- itself and block until the store completes.
  inv.items.storePkg             = {}
  inv.items.storePkg.queryString = queryString or ""
  inv.items.storePkg.endTag      = endTag

  wait.make(inv.items.storeCR)

  return DRL_RET_SUCCESS
end -- inv.items.store(queryString)


function inv.items.storeCR()
  local retval = DRL_RET_SUCCESS
  local idArray

  -- Be paranoid!
  if (inv.items.storePkg == nil) or (inv.items.storePkg.queryString == nil) then
    dbot.error("inv.items.storeCR: Aborting store request -- store package or query is nil!")
    inv.items.storePkg = nil
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local endTag = inv.items.storePkg.endTag

  -- Get an array of object IDs that match the store request's query string
  idArray, retval = inv.items.searchCR(inv.items.storePkg.queryString)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.storeCR: failed to search inventory table: " .. dbot.retval.getString(retval))

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    dbot.info("No match found for store query: \"" .. inv.items.storePkg.queryString .. "\"")
    retval = DRL_RET_MISSING_ENTRY

  -- We found items to store!
  else
    local commandArray = dbot.execute.new()
    local numItemsMoved = 0
    local organizeTargets = inv.items.organize.getTargets()

    for _,objId in ipairs(idArray) do

      -- Check the object's location.  We don't want to store it if it is already in a container
      if (tonumber(inv.items.getField(objId, invFieldObjLoc) or "") ~= nil) then
        dbot.debug("Skipping store request for objId " .. objId .. ": it is already in a container")

      else
        -- The item isn't already in a container so we can store it
        retval = inv.items.storeItem(objId, commandArray, organizeTargets)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.note("Skipping request to store item " .. objId .. ": " .. dbot.retval.getString(retval))
        else
          numItemsMoved = numItemsMoved + 1
        end -- if

        if (commandArray ~= nil) then
          if (#commandArray >= inv.items.burstSize) then
            retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
            if (retval ~= DRL_RET_SUCCESS) then
              dbot.info("Skipping request to store items: " .. dbot.retval.getString(retval))
              break
            end -- if
            commandArray = dbot.execute.new()
          end -- if
        end -- if
      end -- if
    end -- for

    -- Flush any commands in the array that still need to be sent to the mud
    if (retval == DRL_RET_SUCCESS) and (commandArray ~= nil) then
      retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.info("Skipping request to store items: " .. dbot.retval.getString(retval))
      end -- if
    end -- if

    if (retval == DRL_RET_SUCCESS) then
      dbot.info("Store request matched " .. numItemsMoved .. " items")
    end -- if

  end -- if

  inv.items.storePkg = nil

  inv.tags.stop(invTagsStore, endTag, retval)
end -- inv.items.storeCR


function inv.items.storeItem(objId, commandArray, organizeTargets)
  local retval
  local targetContainer = nil

  -- Priority 1: Use organize rules if a target container was found
  if (organizeTargets ~= nil) and (organizeTargets[objId] ~= nil) then
    targetContainer = organizeTargets[objId]
  end -- if

  -- Priority 2: Fall back to the item's home container
  if (targetContainer == nil) then
    targetContainer = tonumber(inv.items.getField(objId, invFieldHomeContainer) or "none")
  end -- if

  -- If no target container was found, put the item in the main inventory instead
  if (targetContainer == nil) then
    retval = inv.items.getItem(objId, commandArray)
  else
    retval = inv.items.putItem(objId, targetContainer, commandArray, true)
  end -- if

  return retval
end -- inv.items.storeItem


----------------------------------------------------------------------------------------------------
-- Routines to handle wearing items
--
-- inv.items.wearItem(objId, objLoc, commandArray, doCheckLocation) -- must be called from a co-routine
-- inv.items.wearSetupFn()   
-- inv.items.wearResultFn()
--
-- Verbage:
--  "You do not have that item."     -- wear BADNAME
--  "You wear ..."                   -- wear item
--  "You wield ..."                  -- weapon
--  "You hold ..."                   -- held item
--  "You light ..."                  -- wear light
--  "You equip ..."                  -- wear portal or sleeping bag
--  "... begins floating around you" -- wear float
--  "... begins floating above you"  -- wear aura of trivia
----------------------------------------------------------------------------------------------------


-- There could be cases where we know for a fact that the plugin doesn't have the correct location
-- info (e.g., we do an atomic get/id/put) available and this give us a way to avoid unnecessary checks.
function inv.items.wearItem(objId, targetLoc, commandArray, doCheckLocation)
  local retval = DRL_RET_SUCCESS

  objId = tonumber(objId or "")
  if (objId == nil) then
    dbot.warn("inv.items.wearItem: Missing valid object ID parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  targetLoc = targetLoc or "" -- this is an optional parameter

  local itemName = (inv.items.getField(objId, invFieldColorName) or "Unidentified") .. DRL_ANSI_WHITE .. "@W"

  -- If we are already wearing the item, don't do anything -- we're good.
  if (commandArray == nil) or doCheckLocation then
    if inv.items.isWorn(objId) then
      dbot.note("Item \"" .. itemName .. "\" is already worn")
      return DRL_RET_SUCCESS
    end -- if

    -- Start with the item in your main inventory
    retval = inv.items.getItem(objId, commandArray)
    if (retval ~= DRL_RET_SUCCESS) then
      if (retval ~= DRL_RET_MISSING_ENTRY) then
        dbot.warn("inv.items.wearItem: Failed to get item \"" .. itemName .. "\": " .. 
                  dbot.retval.getString(retval))
      end -- if

      return retval
    end -- if
  end -- if

  -- Aard is a bit quirky for quivers.  The location reported via identify is "ready" but aard will
  -- only wear a quiver at the "readied" slot.  Ugh.
  if (targetLoc == inv.wearLoc[invWearableLocReady]) then
    targetLoc = invWearableLocReadyWorkaround
  end -- if

  local wearCommand = "wear " .. objId .. " " .. targetLoc

  if (commandArray ~= nil) then
    table.insert(commandArray, wearCommand)
    return retval
  end -- if

  -- Be paranoid and ensure the object is in the main inventory
  local objLoc = inv.items.getField(objId, invFieldObjLoc) or ""
  if (objLoc ~= invItemLocInventory) then
    dbot.warn("inv.items.wearItem: Item \"" .. itemName .. "\" is not in main inventory as expected")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  dbot.note("  Wearing \"" .. itemName .. "\"")

  -- Execute the "wear" command
  local resultData = dbot.callback.new()
  retval = dbot.execute.safe.command(wearCommand, inv.items.wearSetupFn, nil,
                                     inv.items.wearResultFn, resultData)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.note("Skipping request to wear \"" .. itemName .. "\": " .. dbot.retval.getString(retval))
  else
    -- Wait until we have confirmation that the callback completed
    retval = dbot.callback.wait(resultData, 5)
    if (retval ~= DRL_RET_SUCCESS) then
    dbot.note("Skipping request to wear \"" .. itemName .. "\": " .. dbot.retval.getString(retval))
      return retval
    end -- if

    -- Wait until we have confirmation the invmon trigger knows we are wearing the item
    local totTime = 0
    local timeout = 2
    while (inv.items.isWorn(objId) == false) do
      if (totTime > timeout) then
        if inv.items.isInvis(objId) then
          dbot.info("Failed to wear invisible item \"" .. itemName .. "\": can you detect invis?")
        else
          dbot.warn("inv.items.wearItem: Timed out waiting for invmon to confirm we are wearing \"" .. 
                    itemName .. "\"")
        end -- if
        retval = DRL_RET_MISSING_ENTRY
        break
      end -- if

      wait.time(drlSpinnerPeriodDefault)
      totTime = totTime + drlSpinnerPeriodDefault
    end -- if
  end -- if

  return retval
end -- inv.items.wearItem


function inv.items.wearSetupFn()
  EnableTrigger(inv.items.trigger.wearName, true)
end -- inv.items.wearSetupFn


function inv.items.wearResultFn(resultData, retval)
  EnableTrigger(inv.items.trigger.wearName, false)
  dbot.callback.default(resultData, retval)
end -- inv.items.wearResultFn


function inv.items.isWorn(objId)
  local objLoc = inv.items.getField(objId, invFieldObjLoc) or ""

  for _, entry in pairs(inv.wearLoc) do
    if (objLoc == entry) then
      dbot.debug("inv.items.isWorn: item " .. objId .. " is worn at location \"" .. entry .. "\"")
      return true
    end -- if
  end -- for

  return false
end -- inv.items.isWorn


-- This checks if the parameter is a valid wearable location (e.g, "head" or "neck2").  This is
-- slightly different from the inv.items.isWearableType() function which checks for general types
-- such as "neck" or "finger" instead of specific locations like "neck2" or "lfinger" like we do here.
function inv.items.isWearableLoc(wearableLoc)
  for _, loc in pairs(inv.wearLoc) do
    if (wearableLoc == loc) then
      return true
    end -- if
  end -- for

  return false
end -- inv.items.isValidLoc


-- Determines if the input parameter is a general wearable location type like "neck" or "finger".
-- This is slightly different from inv.items.isWearableLoc() which checks for specific wearable
-- locations such as "neck2" or "rfinger".
function inv.items.isWearableType(wearableType)
  if (wearableType == nil) or (wearableType == "") or (inv.wearables[wearableType] == nil) then
    return false
  else
    return true
  end -- if
end -- inv.items.isWearableType


-- This function converts a wearable type (e.g., "neck") into a string holding the specific
-- wearable locations that match the type (e.g., "neck1 neck2").
function inv.items.wearableTypeToLocs(wearableType)
  if (wearableType == nil) or (wearableType == "") or (inv.wearables[wearableType] == nil) then
    return ""
  end -- if

  local wearableArray = inv.wearables[wearableType]
  local wearableLocs = ""

  for i, wearableLoc in ipairs(wearableArray) do
    if (i == 1) then
      wearableLocs = wearableLoc
    else
      wearableLocs = wearableLocs .. " " .. wearableLoc
    end -- if
  end -- for

  return wearableLocs
end -- inv.items.wearableTypeToLocs


----------------------------------------------------------------------------------------------------
-- Routines to handle removing items
--
-- inv.items.removeItem(objId, commandArray) -- must be called from a co-routine
-- inv.items.removeSetupFn()   
-- inv.items.removeResultFn()
--
-- Verbage:
--  "You are not wearing that item."  -- remove BADNAME
--  "You remove .*"                   -- wear item
--  "You stop wielding .*"            -- weapon
--  ".* stops floating around you.*"  -- float
--  ".* stops floating above you.*"   -- above
--  "You stop using.* as a portal.*"  -- portal
--
----------------------------------------------------------------------------------------------------

function inv.items.removeItem(objId, commandArray)
  local retval = DRL_RET_SUCCESS

  objId = tonumber(objId or "")
  if (objId == nil) then
    dbot.warn("inv.items.removeItem: Missing valid object ID parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  local itemName = (inv.items.getField(objId, invFieldColorName) or "Unidentified") .. DRL_ANSI_WHITE .. "@W"

  -- If we are not wearing the item, don't do anything -- we're good.
  if (inv.items.isWorn(objId) == false) then
    --dbot.debug("Item \"" .. itemName .. "\" is not worn")
    return DRL_RET_SUCCESS
  end -- if

  local removeCommand = "remove " .. objId
  if (commandArray ~= nil) then
    table.insert(commandArray, removeCommand)
  else
    dbot.note("  Removing \"" .. itemName .. "\"")

    -- Execute the "remove" command
    local resultData = dbot.callback.new()
    retval = dbot.execute.safe.command(removeCommand, inv.items.removeSetupFn, nil,
                                       inv.items.removeResultFn, resultData)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.note("Skipping remove request: " .. dbot.retval.getString(retval))
    else
      -- Wait until we have confirmation that the callback completed
      retval = dbot.callback.wait(resultData, 5)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.note("Skipping remove request: " .. dbot.retval.getString(retval))
        return retval
      end -- if

      -- Wait until we have confirmation the invmon trigger knows we removed the item
      local totTime = 0
      local timeout = 2
      while inv.items.isWorn(objId) do
        if (totTime > timeout) then
          if inv.items.isInvis(objId) then
            dbot.info("Failed to remove invisible item \"" .. itemName .. "\": can you detect invis?")
          else
            dbot.warn("inv.items.removeItem: Timed out waiting for invmon to confirm we removed \"" .. 
                      itemName .. "\"")
          end -- if
          retval = DRL_RET_MISSING_ENTRY
          break
        end -- if

        wait.time(drlSpinnerPeriodDefault)
        totTime = totTime + drlSpinnerPeriodDefault
      end -- while
    end -- if
  end -- if

  return retval
end -- inv.items.removeItem


function inv.items.removeSetupFn()
  EnableTrigger(inv.items.trigger.removeName, true)
end -- inv.items.removeSetupFn


function inv.items.removeResultFn(resultData, retval)
  EnableTrigger(inv.items.trigger.removeName, false)
  dbot.callback.default(resultData, retval)
end -- inv.items.removeResultFn


----------------------------------------------------------------------------------------------------
-- Keyword support
--
-- We give users the ability to add user-defined keywords to items.  They can then be used in
-- queries to search/get/put/organize items.
--
----------------------------------------------------------------------------------------------------

invKeywordOpAdd    = "add"
invKeywordOpRemove = "remove"
inv.items.keywordPkg = nil
function inv.items.keyword(keyword, keywordOperation, queryString, useQuietMode, endTag)
  if (keyword == nil) or (keyword == "") then
    dbot.warn("inv.items.keyword: Missing keyword")
    return inv.tags.stop(invTagsKeyword, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (keywordOperation == nil) or 
     ((keywordOperation ~= invKeywordOpAdd) and (keywordOperation ~= invKeywordOpRemove)) then
    dbot.warn("inv.items.keyword: Invalid keywordOperation")
    return inv.tags.stop(invTagsKeyword, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  useQuietMode = useQuietMode or false

  if (inv.items.keywordPkg ~= nil) then
    dbot.info("Skipping keyword request: another keyword request is in progress")
    return inv.tags.stop(invTagsKeyword, endTag, DRL_RET_BUSY)
  end -- if

  -- We use a background co-routine to perform the keyword add or remove.  The main reason we
  -- do this in the background is that we want to use the background search co-routine to
  -- find items to keyword (or un-keyword) via the query string and the search co-routine only runs
  -- in a co-routine environment due to explicit scheduling requests.
  inv.items.keywordPkg                    = {}
  inv.items.keywordPkg.keyword            = keyword
  inv.items.keywordPkg.keywordOperation   = keywordOperation
  inv.items.keywordPkg.queryString        = queryString or ""
  inv.items.keywordPkg.useQuietMode       = useQuietMode
  inv.items.keywordPkg.endTag             = endTag

  wait.make(inv.items.keywordCR)

  return DRL_RET_SUCCESS
end -- inv.items.keyword


function inv.items.keywordCR()

  local idArray
  local retval
  local i
  local objId
  local numQueryItems = 0
  local numUpdatedKeywords = 0

  if (inv.items.keywordPkg == nil) or (inv.items.keywordPkg.keyword == nil) then
    dbot.error("inv.items.keywordCR: Aborting keyword request -- keyword package or name is nil!")
    inv.items.keywordPkg = nil
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local endTag = inv.items.keywordPkg.endTag

  -- The custom cache will store any relevant customizable pieces from an object.  We don't
  -- bother caching the "clean" keyword because it is updated so frequently and we can easily
  -- get back to a known good state even if it isn't cached.  This will reduce disk overhead.
  local doCacheItem
  if (inv.items.keywordPkg.keyword == invItemsRefreshClean) then
    doCacheItem = false
  else
    doCacheItem = true
  end -- if

  idArray, retval = inv.items.searchCR(inv.items.keywordPkg.queryString, true)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.keywordCR: failed to search inventory table: " .. dbot.retval.getString(retval))

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    -- If we can't find a container for a refresh update, that container probably is just not identified
    -- yet.  We don't want to spam the user with messages about not finding the keyword query in that
    -- case.
    if (inv.items.keywordPkg.keyword == invItemsRefreshClean) then
      dbot.debug("Failed to find container for clean/dirty update.  You probably need a \"dinv refresh\"")
    else
      dbot.info("No match found for keyword query: \"" .. inv.items.keywordPkg.queryString .. "\"")
    end -- if

  else
    numQueryItems = #idArray
    -- Update the keyword for each item that matched the query string
    for i,objId in ipairs(idArray) do
      local keywordField = inv.items.getStatField(objId, invStatFieldKeywords) or ""
      local customEntry

      if (inv.items.keywordPkg.keywordOperation == invKeywordOpAdd) then
        dbot.debug("Adding keyword \"" .. inv.items.keywordPkg.keyword .. "\" to object " .. objId)
        if (keywordField == nil) or (keywordField == "") then
          inv.items.setStatField(objId, invStatFieldKeywords, inv.items.keywordPkg.keyword)
        elseif dbot.isWordInString(inv.items.keywordPkg.keyword, keywordField) then
          dbot.debug("Skipping keyword of item " .. objId .. ": item is already tagged with " .. 
                     inv.items.keywordPkg.keyword)
        else
          inv.items.setStatField(objId, invStatFieldKeywords, keywordField .. " " .. 
                                 inv.items.keywordPkg.keyword)
        end -- if

        numUpdatedKeywords = numUpdatedKeywords + 1

      elseif (inv.items.keywordPkg.keywordOperation == invKeywordOpRemove) then
        local element
        local newKeywordField = ""

        -- Rebuild the keywordField and leave out any flags that match the specified removed flag
        dbot.debug("Removing keyword \"" .. inv.items.keywordPkg.keyword ..
                   "\" from object " .. objId)
        for element in keywordField:gmatch("%S+") do
          if (string.lower(element) ~= string.lower(inv.items.keywordPkg.keyword)) then
            if (newKeywordField == "") then
              newKeywordField = element
            else
              newKeywordField = newKeywordField .. " " .. element
            end -- if
          else
            numUpdatedKeywords = numUpdatedKeywords + 1
          end -- if
        end -- for

        inv.items.setStatField(objId, invStatFieldKeywords, newKeywordField)

      else
        dbot.error("inv.items.keywordCR: Invalid keyword operation detected")
        inv.items.keywordPkg = nil
        return inv.tags.stop(invTagsKeyword, endTag, DRL_RET_INTERNAL_ERROR)
      end -- if

      if (doCacheItem) then
        retval = inv.cache.add(inv.cache.custom.table, objId)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.items.keywordCR: Failed to add keywords to custom cache for object " .. objId ..
                    dbot.retval.getString(retval))
        end -- if
      end -- if
    end -- for
  end -- if

  if (not inv.items.keywordPkg.useQuietMode) then
    dbot.info("Updated keyword \"" .. (inv.items.keywordPkg.keyword or "Unknown")  .. "\" for " .. 
              numUpdatedKeywords .. " out of " .. numQueryItems .. " items matching query")
  end -- if

  -- Save the updated items and custom cache to disk if we just updated keywords for one or more
  -- items and the keywords are cacheable
  if doCacheItem and (numUpdatedKeywords > 0) then
    for _, objId in ipairs(idArray) do
      dinv_db.saveItem(objId, inv.items.table[objId])
    end
    inv.cache.saveCustom()
  end -- if

  inv.items.keywordPkg = nil

  return inv.tags.stop(invTagsKeyword, endTag, retval)

end -- inv.items.keywordCR


-- A query consists of an array of k-v arrays (e.g., { { "type", "weapon" }, { "minlevel", "100" } }).
-- However, this function supports an array of queries and the result is the "OR" or any query matches.
-- For example, here is an array of query arrays that matches on items that are either weapons under
-- L100 or are shields under L100:
--   { { { invStatFieldType, "weapon" },     { "minlevel", "100" } },
--     { { invStatFieldWearable, "shield" }, { "minlevel", "100" } }
--   }
-- NOTE: A full SQL search engine (translating all query types including keyword/flag word-matching,
-- spells table, and relative names into SQL) was considered but deferred. The hybrid SQL+Lua
-- pre-filtering added in v3.0037 handles the most common queries via SQL, and the remaining
-- Lua-only cases (word-matching, spells, relative names) are inherently hard to express in SQL
-- without significant complexity. Revisit only if inventory sizes grow beyond ~1000 items.
function inv.items.search(arrayOfQueryArrays, allowIgnored)
  local retval = DRL_RET_SUCCESS
  local idArray = {}

  if (arrayOfQueryArrays == nil) then
    dbot.warn("inv.items.search: query array is nil")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  for _, queryArray in ipairs(arrayOfQueryArrays) do

    -- Pre-compute usedIds for any "unused <priorityName | all>" filters in this query branch.
    -- Walking inv.set.table is O(thousands of entries); cache once per branch keyed by the
    -- (lowercased) priority value so the per-item check is O(1).
    local usedIdsByPriority = nil  -- nil if no "unused" filter in this branch
    for _, q in ipairs(queryArray) do
      local pkey = string.lower(q[1] or "")
      if (pkey:sub(1, 1) == "~") then pkey = pkey:sub(2) end -- strip inversion for the lookup
      if (pkey == "unused") then
        -- Sets are lazy-loaded; ensure the table is populated before priorityHasSets/
        -- collectUsedIds read it.  Idempotent (no-op if already loaded).
        inv.set.ensureLoaded()
        local pri = string.lower(q[2] or "")
        if (pri == "") then
          dbot.warn("inv.items.search: \"unused\" query requires a priority name or \"all\"")
          return nil, DRL_RET_INVALID_PARAM
        end -- if
        if (usedIdsByPriority == nil) then usedIdsByPriority = {} end
        if (usedIdsByPriority[pri] == nil) then
          local prioritiesToCheck
          if (pri == "all") then
            prioritiesToCheck = inv.unused.partitionPriorities()
            if (#prioritiesToCheck == 0) then
              dbot.info("\"unused all\": no priorities have analyze data, every item will match")
            end -- if
          elseif (inv.priority.table ~= nil) and (inv.priority.table[pri] ~= nil) then
            if (not inv.unused.priorityHasSets(pri)) then
              dbot.info("Priority \"" .. pri .. "\" has no analyze data; \"unused " .. pri ..
                        "\" will match every item")
            end -- if
            prioritiesToCheck = { pri }
          else
            dbot.warn("inv.items.search: \"unused\" priority \"" .. pri .. "\" does not exist")
            return nil, DRL_RET_MISSING_ENTRY
          end -- if
          usedIdsByPriority[pri] = inv.unused.collectUsedIds(prioritiesToCheck)
        end -- if
      end -- if
    end -- for

    -- Pre-filter via SQL for simple criteria (level, type, name, etc.)
    -- Returns a set of candidate obj_ids, or nil if no SQL filtering is possible
    local sqlCandidates = dinv_db.searchItems(queryArray)

    -- Walk through the inventory table looking for entries that match the requested queries
    for itemId,itemObj in pairs(inv.items.table) do

      -- If SQL pre-filtering produced candidates, skip items not in the set
      if sqlCandidates and not sqlCandidates[itemId] then
        -- Item was excluded by SQL; skip Lua matching
      else

      -- Verify that the inventory entry looks reasonable
      assert(itemId ~= nil, "inv.items.search: inventory table key is nil")
      if (itemObj == nil) then
        dbot.warn("inv.items.search: invalid nil entry found for item " .. itemId)
        return nil, DRL_RET_MISSING_ENTRY
      end -- if

      -- Check if the item is ignored (it either has the ignored flag or is in a container that is ignored).
      -- If it is ignored, don't include the item in search results unless the caller specifically said
      -- to include ignored items.
      local ignoreItem = false
      if inv.items.isIgnored(itemId) and (allowIgnored ~= true) then
        ignoreItem = true
      end -- if

      -- Check if the item already matches the query.  This could happen if we have something of the
      -- form "query1 or query2" and the item matches both query1 and query2.  If the item is already
      -- known to match, then we don't want to waste time checking other query clauses and we don't
      -- want to duplicate it in the array of IDs that we return.
      local idAlreadyMatches = false
      for _, id in ipairs(idArray) do
        if (tonumber(itemId) == tonumber(id)) then
          idAlreadyMatches = true
        end -- if
      end -- for

      -- Get the stats entry for the given item and check if it matches the queries in the query array
      local itemMatches = false
      local objLoc = itemObj[invFieldObjLoc]
      local stats = itemObj[invFieldStats]
      if (stats ~= nil) and (idAlreadyMatches == false) and (ignoreItem == false) then
        itemMatches = true -- start by assuming we have a match and halt if we find any non-conforming query

        -- If we have an empty query (query == "") and the item is equipped, we don't match it.  The
        -- empty query refers to everything that is not equipped.
        if (queryArray ~= nil) and (#queryArray == 0) and inv.items.isWorn(itemId) then
          itemMatches = false
        end -- if

        for queryIdx,query in ipairs(queryArray) do
          local key = string.lower(query[1])   -- Stat keys and values are lower case to avoid conflicts
          local value = string.lower(query[2])
          local valueNum = tonumber(query[2])

          if (key == nil) or (value == nil) then
            dbot.warn("inv.items.search: query " .. queryIdx .. " is malformed with a nil component")
            return nil, DRL_RET_MISSING_ENTRY
          end -- if

          -- There are a few "one-off" search queries that make life simplier.  We support the
          -- "all", "equipped" (or "worn"), and "unequipped" search queries.
          if (key == invQueryKeyCustom) then

            if (value == invQueryKeyAll) then
              itemMatches = true
            elseif (value == invQueryKeyEquipped) and (not inv.items.isWorn(itemId)) then
              itemMatches = false
            elseif (value == invQueryKeyUnequipped) and inv.items.isWorn(itemId) then
              itemMatches = false
            end -- if

            break
          end -- if

          -- Check if the query has a prefix.  We currently support the prefixes "~", "min", and "max".
          local prefix = ""
          local base = ""
          local invert = false

          _, _, prefix, base = string.find(key, "(~)(%S+)")
          if (prefix ~= nil) and (base ~= nil) then
            invert = true
            key = base
          end -- if

          _, _, prefix, base = string.find(key, "(min)(%S+)")
          if (prefix ~= nil) and (base ~= nil) then
            key = base
          else
            _, _, prefix, base = string.find(key, "(max)(%S+)")
            if (prefix ~= nil) and (base ~= nil) then
              key = base
            end -- if
          end -- if

          local statsVal = stats[key] or ""
          local statsNum = tonumber(stats[key] or 0)

          -- Ensure that "min" and "max" queries are only used on numbers
          if (prefix == "min") or (prefix == "max") then
            if (valueNum == nil) or (statsNum == nil) then
              dbot.warn("inv.items.search: min or max prefix was used on non-numerical query")
              return DRL_RET_INVALID_PARAM
            end -- if
          end -- if

          -- We don't keep meta-information about the item (e.g., location, id level, etc.) inside the
          -- stats table but our search queries are all relative to entries in the stats table.  One
          -- exception to this is the objectLocation field.  It's a little awkward moving that to the
          -- stats table and we don't want to duplicate it...so...we use a little kludge here and
          -- explicitly check for a location query and handle it as a one-off.  Yes, I should probably
          -- fix this at some point...
          if (key == invQueryKeyLocation) or (key == invQueryKeyLoc) then
            if ((invert == false) and ((valueNum ~= nil) and (valueNum ~= objLoc))) or
               ((invert == true)  and ((valueNum ~= nil) and (valueNum == objLoc))) then
              itemMatches = false
              break
            end -- if

          -- "unused <priorityName | all>": match items NOT in the analyzed sets table for the
          -- named priority.  "~unused" inverts (match items that ARE in the analyzed sets).
          -- The pre-scan above built usedIdsByPriority; here we just do an O(1) lookup.
          elseif (key == "unused") then
            local pri = value -- already lowercased by the caller
            local usedIds = (usedIdsByPriority ~= nil) and usedIdsByPriority[pri] or nil
            local isUsed = (usedIds ~= nil) and (usedIds[tonumber(itemId) or itemId] == true) or false
            if ((invert == false) and isUsed) or ((invert == true) and (not isUsed)) then
              itemMatches = false
              break
            end -- if

          -- If we are searching for an element in a string of elements (e.g., a keyword in a keyword list
          -- or a flag in a list of flags) check if the queried string is present.  We use a case-insensitive
          -- search by making everything in the strings lower case.  We also temporarily replace special
          -- characters in the search strings with their escaped equivalents (e.g., "-" becomes "%-") so 
          -- that we can search for things like "anti-evil" without the hyphen being interpreted as a
          -- special character.
          --
          -- Some string fields (name and leadsTo) support a partial match.  For example, searching for 
          -- "Nation" in the "leadsTo" field would match for both "Imperial Nation" and "The Amazon Nation".
          -- Other string fields (keywords and flags) require an exact match so searching for the
          -- "evil" flag won't match on "anti-evil".

          elseif (key == invStatFieldName) or (key == invStatFieldLeadsTo) or (key == invStatFieldFoundAt) then
            local escapedValue = string.gsub(value, "[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%1")
            local noMatch = (string.find(string.lower(statsVal), string.lower(escapedValue)) == nil)
            if ((invert == false) and noMatch) or ((invert == true) and not noMatch) then
              itemMatches = false
              break
            end -- if

          elseif (key == invStatFieldKeywords) or (key == invStatFieldFlags)    or
                 (key == invStatFieldClan)     or (key == invStatFieldWearable) then
            local statField = statsVal or ""
            local element
            local isInField = false

            for element in statField:gmatch("%S+") do
              element = string.gsub(element, ",", "")
              if (string.lower(element) == string.lower(value)) then
                isInField = true
                break
              end -- if
            end -- for

            -- Yes, this reduces to "if invert == isInField" but I can't bring myself to use that
            -- because I know I'll forget the simplifiication by the next time I look at this code...
            if ((invert == false) and (isInField == false)) or
               ((invert == true)  and (isInField == true)) then
              itemMatches = false
              break
            end -- if

          -- Check for a min or a max query
          elseif ((invert == false) and (prefix == "min") and (statsNum <  valueNum)) or
                 ((invert == true)  and (prefix == "min") and (statsNum >= valueNum)) or
                 ((invert == false) and (prefix == "max") and (statsNum >  valueNum)) or
                 ((invert == true)  and (prefix == "max") and (statsNum <= valueNum)) then
            itemMatches = false
            break

          -- Check for entries that aren't present (defaults to "0")
          elseif (statsVal == "") then
            if ((invert == false) and (statsNum ~= valueNum)) or
               ((invert == true)  and (statsNum == valueNum)) then
              itemMatches = false
              break
            end -- if

          -- Handle a "spells" name search.  The spells are in a table so we need to handle
          -- this a little differently than normal so that we can unpack the table.
          elseif (key == invStatFieldSpells) and (type(statsVal) == "table") then
            local foundSpell = false
            for _,spellEntry in ipairs(statsVal) do
              if dbot.isWordInString(string.lower(value), spellEntry.name) then
                foundSpell = true
                break
              end -- if
            end -- for

            if (foundSpell and (invert == true)) or ((not foundSpell) and (invert == false)) then
              itemMatches = false
              break
            end -- if

          -- Handle a basic string query (use lowercase only to make queries a bit simpler)
          elseif ((invert == false) and (prefix == nil) and (type(statsVal) ~= "table") and
                  (string.lower(statsVal) ~= string.lower(value))) or
                 ((invert == true)  and (prefix == nil) and (type(statsVal) ~= "table") and
                  (string.lower(statsVal) == string.lower(value))) then
            itemMatches = false
            break
          end -- if

        end -- for
      end -- if
      
      if (itemMatches == true) then
        table.insert(idArray, tonumber(itemId))
      end -- if
      end -- if sqlCandidates skip
    end -- for
  end -- for

  return idArray, retval
end -- inv.items.search


-- Parse the string containing one or more search queries into an array of { key, value } where
-- each element is one component of the full query
-- Example queryStrings:
--   wearable hold maxlevel 10
--   level 11 type armor
--   keywords aardwords
--   flags glow minint 5
--   loc 123456789
--   name bob
--   keyword shardblade
-- Note: This must be called from within a co-routine because inv.items.convertRelative() can block
function inv.items.searchCR(rawQueryString, allowIgnored) 
  local retval = DRL_RET_SUCCESS
  local arrayOfKvArrays = {}
  local kvArray = {}
  local idx = 1
  local key = ""
  local value = ""
  local element
  local numWordsInQuery = 0

  if (rawQueryString == nil) then
    dbot.warn("inv.items.searchCR: Missing query string parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- Raw materials are the one type that has a space in the name (e.g., "Raw material:Ore").
  -- Internally, we treat the type as "RawMaterial:[whatever]".
  local queryString = string.gsub(rawQueryString, "type[ ]+[rR]aw[ ]+[mM]aterial", "type RawMaterial")

  -- Count the number of words in the query string.  We use an obscure form of gsub() for this.
  -- The gsub function's 2nd return value is the number of substitutions made.  If we do a dummy
  -- substitution for each block of non-space characters in the query, we can get a count of the
  -- number of words in the query.
  if (queryString ~= nil) and (queryString ~= "") then
    _, numWordsInQuery = queryString:gsub("%S+", "")
  end -- if

  -- An empty query matches everything that is not equipped
  if (queryString == "") then
    table.insert(kvArray, { invQueryKeyCustom, invQueryKeyUnequipped })

  -- A query that only consists of "all" will match everything -- including equipped items
  elseif (Trim(queryString) == invQueryKeyAll) then
    table.insert(kvArray, { invQueryKeyCustom, invQueryKeyAll })

  -- You can match all worn equipment with the "equipped" or "worn" query
  elseif (Trim(queryString) == invQueryKeyEquipped) or (Trim(queryString) == invQueryKeyWorn) then
    table.insert(kvArray, { invQueryKeyCustom, invQueryKeyEquipped })

  -- If there is just a single word in the queryString, assume it is a name search.
  -- We don't really need to support this, but it is a convenient kludge.
  elseif (numWordsInQuery == 1) then
    table.insert(kvArray, { invStatFieldName, queryString })

  else
    -- Parse the query string into key-value pairs and pass those pairs to inv.items.search()
    -- to search the inventory table for items matching each key-value query
    for element in queryString:gmatch("%S+") do
      -- If we hit the "OR" operator, close the current query and start a new one
      if (element == "||") then
        table.insert(arrayOfKvArrays, kvArray)
        kvArray = {}

      -- If we are in a query and we are at the key location (it goes key then value), then save the key
      elseif ((idx % 2) ~= 0) then
        key = element
        idx = idx + 1

      -- If we are in a query and we are at the value location (it goes key then value), then save the value
      else
        value = element
        --dbot.debug("key=\"" .. key .. "\", value=\"" .. value .. "\"")

        -- If we are inverting the key field (e.g., "level" vs. "~level") then we want to temporarily
        -- strip the "~" from the key, process the remaining key, and then add the "~" back before we
        -- put the query into the returned array.  We could leave the "~" in place, but it reduces the
        -- parsing complexity if we pull it out before we do checks against the key type.
        local isInverted = string.find(key, "^~.*")
        if isInverted then
          key = string.gsub(key, "^~", "")
        end -- if

        -- If a query has a relative name or loc in it, convert the name or loc to an object ID here
        if (key == invQueryKeyRelativeName) or (key == invQueryKeyRelativeLoc) or 
           (key == invQueryKeyRelativeLocation) then
          key, value, retval = inv.items.convertRelative(key, value) -- new value is ID of relative item
          if (retval ~= DRL_RET_SUCCESS) then
            return nil, retval
          end -- if
        end -- if

        -- Add shortcuts to some commonly used query keys
        if (key == invQueryKeyKey) or (key == invQueryKeyKeyword) then
          key = invStatFieldKeywords
        elseif (key == invQueryKeyFlag) then
          key = invStatFieldFlags
        end -- if

        -- Add the "~" back to the key name if we stripped the inversion prefix off before parsing the key
        if (isInverted) then
          key = "~" .. key
        end -- if

        table.insert(kvArray, { key, value })
        idx = idx + 1
      end -- if

    end -- for
  end -- if

  -- Close the final query and add it to the array of queries
  table.insert(arrayOfKvArrays, kvArray)

  -- Convert the series of queries in an array of object IDs that match the queries
  local idArray, retval = inv.items.search(arrayOfKvArrays, allowIgnored)

  return idArray, retval

end -- inv.items.searchCR


-- Finds object ids matching rawQueryString
-- Returns a comma-separated list of object ids as a string
-- Note: This function may be called externally with CallPlugin.
--       As such, relative names and relative locations are not allowed.
-- Note: (Durel)
--      The code below was largely written by jontsai and submitted as a pull request on github.
--      I moved the bulk of the code from getItemIds() to inv.items.searchIdsCSV() just to keep the
--      namespace consistent.  I left getItemIds() as a function though so I don't break any
--      plugins that use the code.  It's the least I can do since he wrote this :P
function getItemIds(rawQueryString)
  return inv.items.searchIdsCSV(rawQueryString)
end -- getItemIds(rawQueryString)


function inv.items.searchIdsCSV(rawQueryString)
  local itemIds = ''

  -- If the query has anything dependent on a relative name or location, warn the caller and return
  if inv.items.isSearchRelative(rawQueryString) then
    dbot.warn("inv.items.searchIdsCSV: Skipping request containing relative names or locations which " ..
              "are not available outside of a co-routine")

  else
    local idArray, retval = inv.items.searchCR(rawQueryString)

    local count = 0
    for _, objId in ipairs(idArray) do
      if count > 0 then
        itemIds = itemIds .. ','
      end
        itemIds = itemIds .. objId
        count = count + 1
    end
  end

  return itemIds
end -- inv.items.searchIdsCSV(rawQueryString)


function inv.items.isSearchRelative(query)
  if string.find(query, inv.stats.rname.name)     or
     string.find(query, inv.stats.rloc.name)      or
     string.find(query, inv.stats.rlocation.name) then
    return true
  else
    return false
  end -- if
end -- inv.items.isSearchRelative


-- Return an array of objIds that is a sorted version of the idArray given as an input param
-- E.g., to sort first by type and then by level, use a fieldArray like this:
--   fieldArray = { { field = invStatFieldType, isAscending = true },
--                  { field = invStatFieldLevel, isAscending = true } }
function inv.items.sort(idArray, fieldArray)
  if (idArray == nil) or (fieldArray == nil) then
    dbot.warn("inv.items.sort: required input parameter is nil")
    return DRL_RET_INVALID_PARAM
  end -- if

  inv.items.compareArray = fieldArray
  table.sort(idArray, inv.items.compare)

  return DRL_RET_SUCCESS

end -- inv.items.sort


inv.items.compareArray = nil
function inv.items.compare(item1, item2)

  for i, sortEntry in ipairs(inv.items.compareArray) do

    local fieldName = sortEntry.field
    assert(fieldName ~= nil, "sorting field is missing")

    local isAscending = sortEntry.isAscending
    if (isAscending == nil) then
      currentIsAscending = true -- default to "true" if the user doesn't specify an order
    end -- if

    field1 = inv.items.getStatField(item1, fieldName) or "unknown"
    field2 = inv.items.getStatField(item2, fieldName) or "unknown"
    fieldNum1 = tonumber(field1)
    fieldNum2 = tonumber(field2)

    -- If we are comparing one number and one string then something is wrong
    if ((fieldNum1 == nil) and (fieldNum2 ~= nil)) or ((fieldNum1 ~= nil) and (fieldNum2 == nil)) then
      return false
    end -- if

    -- If we have two numbers, compare the two numbers.  If they are equal, move to the next sorting element.
    -- Otherwise, return with a boolean indicating which one is first.
    if (fieldNum1 ~= nil) and (fieldNum2 ~= nil) and (fieldNum1 ~= fieldNum2) then
      if (isAscending) then 
         return fieldNum1 < fieldNum2
      else
         return fieldNum1 > fieldNum2
      end -- if
    end -- if

   -- If we have two non-numerical strings, compare them!
   if (fieldNum == nil) and (fieldNum2 == nil) and (field1 ~= field2) then
     if (isAscending) then 
       return field1 < field2
     else
       return field1 > field2
     end -- if
   end -- if

  end -- for

  -- We made it through all of the sort specifications without finding any differences between the
  -- two items.  They are equivalent based on the fields given as parameters.
  return false

end -- inv.items.compare


function inv.items.convertRelative(relativeName, value)
  local key = nil
  local id = nil
  local retval = DRL_RET_SUCCESS

  if (value == nil) then
    dbot.warn("inv.items.convertRelative: nil value parameter detected")
    return key, id, DRL_RET_INVALID_PARAM
  end -- if

  if (relativeName == invQueryKeyRelativeName) then
    key = invStatFieldId
  elseif (relativeName == invQueryKeyRelativeLoc) or (relativeName == invQueryKeyRelativeLocation) then
    key = invQueryKeyLocation
  end -- if

  inv.lastIdentifiedObjectId = nil

  local resultData = dbot.callback.new()

  local commandArray = {}
  table.insert(commandArray, "identify " .. value)
  table.insert(commandArray, "echo " .. inv.items.identifyFence)
  retval = dbot.execute.safe.commands(commandArray, inv.items.convertSetupFn, nil,
                                      dbot.callback.default, resultData) 
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.convertRelative: Failed to submit safe identification call: " ..
              dbot.retval.getString(retval))
    inv.lastIdentifiedObjectId = 0
  else
    -- Wait until we know the relative item's object ID
    retval = dbot.callback.wait(resultData, inv.items.timer.idTimeoutThresholdSec)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.note("Skipping relative name identify request: " .. dbot.retval.getString(retval))
      inv.lastIdentifiedObjectId = 0
    end -- if
  end -- if

  -- Grab the ID for the most recently identified object
  if (inv.lastIdentifiedObjectId == 0) then
    dbot.note("Skipping request: relative name \"" .. value ..
              "\" did not match any item in your main inventory")
    EnableTrigger(inv.items.trigger.idItemName, false)
    key = nil
    id = nil
    retval = DRL_RET_MISSING_ENTRY
  else
    id = inv.lastIdentifiedObjectId
  end -- if

  inv.lastIdentifiedObjectId = nil
  
  return key, id, retval
end -- inv.items.convertRelative


function inv.items.convertSetupFn()
  EnableTrigger(inv.items.trigger.idItemName, true)
end -- inv.items.convertSetupFn



invDisplayVerbosityBasic       = "basic"      -- default mode
invDisplayVerbosityId          = "objid"
invDisplayVerbosityFull        = "full"
invDisplayVerbosityDiffAdd     = "diffAdd"    -- internal only (shows diff format for replaced items)
invDisplayVerbosityDiffRemove  = "diffRemove" -- internal only (shows diff format for replaced items)
invDisplayVerbosityRaw         = "raw"        -- internal only (shows raw table data)

inv.items.displayPkg = nil
-- Asynchronous routine to display results for a query into the inventory table
function inv.items.display(queryString, verbosity, endTag)
  local retval = DRL_RET_SUCCESS

  -- Default to basic display verbosity if nothing is specificed as a parameter
  verbosity = verbosity or invDisplayVerbosityBasic

  -- Check if another display request is in progress before we proceed
  if (inv.items.displayPkg ~= nil) then
    dbot.info("inv.items.display: Skipping display query: another display query is in progress")
    return inv.tags.stop(invTagsSearch, endTag, DRL_RET_BUSY)
  end -- if

  -- Use globals to hold state for the display co-routine
  inv.items.displayPkg             = {}
  inv.items.displayPkg.queryString = queryString
  inv.items.displayPkg.verbosity   = verbosity
  inv.items.displayPkg.endTag      = endTag

  -- Sort the results first by item type, then by item level, then by location, and finally by item name
  inv.items.displayPkg.sortCriteria = { { field = invStatFieldType,     isAscending = true },
                                        { field = invStatFieldLevel,    isAscending = true },
                                        { field = invStatFieldWearable, isAscending = true },
                                        { field = invStatFieldName,     isAscending = true } }

  -- Fire off the asynchronous co-routine to generate and display the results
  wait.make(inv.items.displayCR)

  return retval
end -- inv.items.display


inv.items.displayLastType = ""
function inv.items.displayCR()
  local endTag = inv.items.displayPkg.endTag

  local idArray, retval = inv.items.searchCR(inv.items.displayPkg.queryString)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.displayCR: failed to search inventory table: " .. dbot.retval.getString(retval))

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    dbot.info("@Y0@W items matched query \"@c" .. inv.items.displayPkg.queryString .. "@W\"")

  else
    -- Sort and display the results
    inv.items.sort(idArray, inv.items.displayPkg.sortCriteria)
    inv.items.displayLastType = ""
    for _, objId in ipairs(idArray) do
      inv.items.displayItem(objId, inv.items.displayPkg.verbosity)
    end -- for

    local suffix = "s"
    if (#idArray == 1) then
      suffix = ""
    end -- if
    print("")
    dbot.info("@Y" .. #idArray .. "@W item" .. suffix .. " matched query \"@c" ..
              inv.items.displayPkg.queryString .. "@W\"")
  end -- if

  inv.items.displayPkg = nil

  return inv.tags.stop(invTagsSearch, endTag, retval)
end -- inv.items.displayCR


function inv.items.reportItem(channel, name, level, itemType, itemTable)
  if (itemTable == nil) then
    dbot.warn("inv.items.reportItem: itemTable is missing")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (channel == nil) or (channel == "") then
    dbot.warn("inv.items.reportitem: channel is missing")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (level == nil) or (level == "") then
    dbot.warn("inv.items.reportitem: level is missing")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (itemType == nil) or (itemType == "") then
    dbot.warn("inv.items.reportitem: itemType is missing")
    return DRL_RET_INVALID_PARAM
  end -- if

  local colorIndex = 1
  local colorScheme = { { light = "@x083", dark = "@x002" },
                        { light = "@x039", dark = "@x025" },
--                        { light = "@x190", dark = "@x220" },
--                        { light = "@x255", dark = "@x242" },
--                        { light = "@x039", dark = "@x105" },
--                        { light = "@x144", dark = "@x136" },
--                        { light = "@R", dark = "@r" },
                      }
  
  local reportStr = (name or "Unidentified") .. "@c [@WL" .. level .. " " ..
                    Trim(itemType) .. "@c] @W: "

  for _, block in ipairs(itemTable) do
    for key, value in pairs(block) do
      if ((value ~= 0) and (value ~= "0") and (value ~= "") and (value ~= "none")) or
         (((value == 0) or (value == "0")) and (key == "Wgt")) then

        local currentColors = colorScheme[colorIndex]
        local numVal = tonumber(value or "")

        reportStr = reportStr .. currentColors.dark .. key .. currentColors.light
        if (numVal == nil) then
          reportStr = reportStr .. value .. " "
        else
          reportStr = reportStr .. math.floor(numVal) .. " "
        end -- if

        if (colorIndex == #colorScheme) then
          colorIndex = 1
        else
          colorIndex = colorIndex + 1
        end -- if

      end -- if
    end -- for
  end -- for

  Execute(channel .. " " .. reportStr .. "@w")

  return DRL_RET_SUCCESS

end -- inv.items.reportItem


function inv.items.displayItem(objId, verbosity, wearableLoc, channel)
  if (objId == nil) then
    dbot.warn("inv.items.displayItem: objId is nil")
    return DRL_RET_INVALID_PARAM
  end -- if

  local objIdNum = dbot.tonumber(objId)
  if (objIdNum == nil) then
    dbot.warn("inv.items.displayItem: objId is not a number")
    return DRL_RET_INVALID_PARAM
  end -- if

  local entry = inv.items.getEntry(objId)
  if (entry == nil) then
    dbot.warn("inv.items.displayItem: Item " .. objId .. " is not in the inventory table")
    return DRL_RET_INVALID_ENTRY
  end -- if

  -- Use the default verbosity mode if verbosity is not given
  verbosity = verbosity or invDisplayVerbosityId

  if (verbosity == invDisplayVerbosityRaw) then
    print("\nInventory table key: \"" .. objId .. "\"")
    tprint(entry)
    return DRL_RET_SUCCESS
  end -- if

  local objLoc = inv.items.getField(objId, invFieldObjLoc)
  if (objLoc == nil) then
    dbot.warn("inv.items.displayItem: Item " .. objId .. " does not have a known location")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local colorName  = inv.items.getField(objId, invFieldColorName) or "@RName is not yet identified@w"
  local level      = inv.items.getStatField(objId, invStatFieldLevel) or 0
  local typeField  = inv.items.getStatField(objId, invStatFieldType) or "Unknown"
  local weaponType = inv.items.getStatField(objId, invStatFieldWeaponType) or "Unknown"
  local damtype    = inv.items.getStatField(objId, invStatFieldDamType)  or "none"
  local specials   = inv.items.getStatField(objId, invStatFieldSpecials) or "none"
  local wearable   = inv.items.getStatField(objId, invStatFieldWearable) or ""
  local leadsTo    = inv.items.getStatField(objId, invStatFieldLeadsTo) or "Unknown"
  local spells     = inv.items.getStatField(objId, invStatFieldSpells) or {}

  -- Highlight items that are currently worn (the location isn't a container or inventory)
  local highlightOn = ""
  local highlightOff = ""
  local isCurrentlyWorn = false
  if inv.items.isWorn(objId) and (inv.items.getField(objId, invFieldColorName) ~= "") then
    isCurrentlyWorn = true
    highlightOn = "@W"
    highlightOff = "@w"
  end -- if

  local int      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldInt)      or "0")
  local luck     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldLuck)     or "0")
  local wis      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldWis)      or "0")
  local str      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldStr)      or "0")
  local dex      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldDex)      or "0")
  local con      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldCon)      or "0")
  local avedam   = dbot.tonumber(inv.items.getStatField(objId, invStatFieldAveDam)   or "0")
  local dam      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldDam)      or "0")
  local hit      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldHit)      or "0")
  local hp       = dbot.tonumber(inv.items.getStatField(objId, invStatFieldHP)       or "0")
  local mana     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldMana)     or "0")
  local moves    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldMoves)    or "0")
  local weight   = dbot.tonumber(inv.items.getStatField(objId, invStatFieldWeight)   or "0")

  local allphys  = dbot.tonumber(inv.items.getStatField(objId, invStatFieldAllPhys)  or "0")
  local allmagic = dbot.tonumber(inv.items.getStatField(objId, invStatFieldAllMagic) or "0")

  local slash    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldSlash)    or "0")
  local pierce   = dbot.tonumber(inv.items.getStatField(objId, invStatFieldPierce)   or "0")
  local bash     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldBash)     or "0")

  local acid     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldAcid)     or "0")
  local cold     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldCold)     or "0")
  local energy   = dbot.tonumber(inv.items.getStatField(objId, invStatFieldEnergy)   or "0")
  local holy     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldHoly)     or "0")
  local electric = dbot.tonumber(inv.items.getStatField(objId, invStatFieldElectric) or "0")
  local negative = dbot.tonumber(inv.items.getStatField(objId, invStatFieldNegative) or "0")
  local shadow   = dbot.tonumber(inv.items.getStatField(objId, invStatFieldShadow)   or "0")
  local magic    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldMagic)    or "0")
  local air      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldAir)      or "0")
  local earth    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldEarth)    or "0")
  local fire     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldFire)     or "0")
  local light    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldLight)    or "0")
  local mental   = dbot.tonumber(inv.items.getStatField(objId, invStatFieldMental)   or "0")
  local sonic    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldSonic)    or "0")
  local water    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldWater)    or "0")
  local poison   = dbot.tonumber(inv.items.getStatField(objId, invStatFieldPoison)   or "0")
  local disease  = dbot.tonumber(inv.items.getStatField(objId, invStatFieldDisease)  or "0")

  -- Calculate total physical and magical resists.  We weight a specific physical or magic resist
  -- relative to an "all" resist.  For example, 3 "slash" resists are equivalent to 1 "all" phys resist
  -- because there are 3 physical resist types.  Similarly, one specific magical resist is worth 1/17 of
  -- one "all" magical resist value because there are 17 magical resistance types.
  local physResists = allphys + (slash + pierce + bash) / 3
  local magicResists = allmagic + (acid + cold + energy + holy + electric + negative + shadow + magic + 
                       air + earth + fire + light + mental + sonic + water + poison + disease) / 17
  local totResists = physResists + magicResists

  local capacity        = dbot.tonumber(inv.items.getStatField(objId, invStatFieldCapacity)        or "0")
  local holding         = dbot.tonumber(inv.items.getStatField(objId, invStatFieldHolding)         or "0")
  local heaviestItem    = dbot.tonumber(inv.items.getStatField(objId, invStatFieldHeaviestItem)    or "0")
  local itemsInside     = dbot.tonumber(inv.items.getStatField(objId, invStatFieldItemsInside)     or "0")
  local totWeight       = dbot.tonumber(inv.items.getStatField(objId, invStatFieldTotWeight)       or "0")
  local itemBurden      = dbot.tonumber(inv.items.getStatField(objId, invStatFieldItemBurden)      or "0")
  local weightReduction = dbot.tonumber(inv.items.getStatField(objId, invStatFieldWeightReduction) or "0")

  -- If we are in basic display mode, don't print the object ID; otherwise print it
  local displayObjId = false
  if (verbosity == invDisplayVerbosityId) or (verbosity == invDisplayVerbosityFull) then
    displayObjId = true
  end -- if

  -- If we are in "diff" mode, we prepend the addition or removal indicator to the name of the item
  if (verbosity == invDisplayVerbosityDiffAdd) then
    colorName = "@G>>@W " .. colorName
  elseif (verbosity == invDisplayVerbosityDiffRemove) then
    colorName = "@R<<@W " .. colorName
  end -- if

  -- We color-code the ID field as follows: unidentified = red, partial ID = yellow, full ID = green
  local formattedId = ""
  local colorizedId = ""
  local idPrefix = DRL_ANSI_WHITE
  local idSuffix = DRL_ANSI_WHITE
  local idLevel = inv.items.getField(objId, invFieldIdentifyLevel)
  if (idLevel ~= nil) and (displayObjId == true)  then
    if (idLevel == invIdLevelNone) then
      idPrefix = DRL_ANSI_RED
    elseif (idLevel == invIdLevelPartial) then
      idPrefix = DRL_ANSI_YELLOW
    elseif (idLevel == invIdLevelFull) then
      idPrefix = DRL_ANSI_GREEN
    else
      dbot.error("inv.items.displayItem: Invalid identify level state detected: idLevel")
      return DRL_RET_INTERNAL_ERROR
    end -- if

    formattedId = "(" .. objId .. ") "
    colorizedId = idPrefix .. formattedId .. idSuffix
  end -- if

  -- Format the name field for the stat display.  This is complicated because we have a fixed
  -- number of spaces reserved for the field but color codes could take up some of those spaces.
  -- We iterate through the string byte by byte checking the length of the non-colorized equivalent
  -- to see when we've hit the limit that we can print.
  local maxNameLen = 24
  local formattedName = ""
  local index = 0
  while (#strip_colours(formattedName) < maxNameLen - #formattedId) and (index < 50) do
    formattedName = string.sub(colorName, 1, maxNameLen - #formattedId + index)
    index = index + 1
  end

  if (#strip_colours(formattedName) < maxNameLen - #formattedId) then
    formattedName = formattedName ..
                    string.rep(" ", maxNameLen - #strip_colours(formattedName) - #formattedId)
  end -- if

  -- The trimmed name could end on an "@" which messes up color codes and spacing
  formattedName = string.gsub(formattedName, "@$", " ") .. " " .. DRL_XTERM_GREY
  formattedName = formattedName .. colorizedId 

  -- If we have a wearable location, use it in the display.  Otherwise, use the item's type.
  local typeExtended
  if (invIdLevelNone == inv.items.getField(objId, invFieldIdentifyLevel)) then
    typeExtended = "Unknown"
  elseif (wearableLoc ~= nil) and (wearableLoc ~= "") then
    typeExtended = wearableLoc
  elseif (typeField == invmon.typeStr[invmonTypeWeapon]) then
    if (wearable == inv.wearLoc[invWearableLocReady]) then
      typeExtended = "quiver"
    else
      typeExtended = weaponType
    end -- if
  elseif (typeField == invmon.typeStr[invmonTypeContainer]) then
    typeExtended = "Contain"
  elseif (typeField == "RawMaterial:Ore") then
    typeExtended = "Ore"
  elseif (wearable == "")  or (wearable == invmon.typeStr[invmonTypeHold]) then
    typeExtended = typeField
  else
    typeExtended = wearable
  end -- if
  typeExtended = string.format("%-8s", typeExtended) 

  -- Make the item's type show up in bright green if the item is currently worn
  if (isCurrentlyWorn == true) then
    typeExtended = DRL_ANSI_GREEN .. typeExtended .. DRL_ANSI_WHITE
  end -- if

  -- Truncate some field strings that are limits on how long they can be
  local maxAreaNameLen = 18
  local formattedLeadsTo = string.sub(leadsTo, 1, maxAreaNameLen)
  local formattedType = string.format("%-17s", typeField)

  -- Format the output for the item's stat display
  local header
  local statLine
  local reportLine = ""
  if (typeField == invmon.typeStr[invmonTypePotion]) or 
     (typeField == invmon.typeStr[invmonTypePill]) or 
     (typeField == invmon.typeStr[invmonTypeScroll]) then
    header = "@WLvl Name of " .. formattedType .. "Type    Lvl  # Spell name@w"
    local spellDetails = ""
    local spellReport = ""
    for i,v in ipairs(spells) do
      spellDetails = string.format("%s%3d x%1d %s ", spellDetails, v.level, v.count, v.name)
      spellReport = spellReport .. " L" .. v.level .. " x" .. v.count .. " " .. v.name
    end -- for
    statLine = string.format("@W%3d@w %s%s%s", level, formattedName, typeExtended, spellDetails)

    if (channel ~= nil) then
      inv.items.reportItem(channel,
                           colorName, level, typeExtended,
                           { { Spells = spellReport } })
    end -- if

  -- We don't display # of charges for wands and staves.  First, invitem isn't triggered when you
  -- use a staff or wand so it would be a bit of a pain to try to trigger on each brandish/zap, find
  -- the staff/wand used and update the charges.  It's do-able, but just not implemented yet.  The
  -- bigger reason to ignore charges for wands and staves is the frequent item cache.  If we use #
  -- of charges to distinguish wands and staves, we can't put them in the frequent item cache since
  -- one instance of a wand/staff may not be identical to other instances.  Since they aren't identical,
  -- we'd need to ID each item -- which defeats the purpose of caching the info in the first place.
  -- Trust me, if you buy 100 starburst staves, you'd rather have them in the frequent cache even if
  -- it means your inventory table doesn't know how many charges are on each instance.
  elseif (typeField == invmon.typeStr[invmonTypeWand]) or 
         (typeField == invmon.typeStr[invmonTypeStaff]) then
    header = "@WLvl Name of " .. formattedType .. "Type    Lvl  Spell name@w"
    local spellDetails = ""
    local spellReport = ""
    for i,v in ipairs(spells) do
      spellDetails = string.format("%s%3d  %s ", spellDetails, v.level, v.name)
      spellReport = spellReport .. " L" .. v.level .. " " .. v.name
    end -- for
    statLine = string.format("@W%3d@w %s%s%s", level, formattedName, typeExtended, spellDetails)
    if (channel ~= nil) then
      inv.items.reportItem(channel,
                           colorName, level, typeExtended,
                           { { Spells = spellReport } })
    end -- if

  elseif (typeField == invmon.typeStr[invmonTypePortal]) then
    header = "@WLvl Name of " .. formattedType ..
             "Type     Leads to            HR  DR Int Wis Lck Str Dex Con@w"
    statLine = string.format("@W%3d@w %s%s %-18s %s %s %s %s %s %s %s %s",
                             level, formattedName, typeExtended, formattedLeadsTo,
                             inv.items.colorizeStat(hit, 3), inv.items.colorizeStat(dam, 3), 
                             inv.items.colorizeStat(int, 3), inv.items.colorizeStat(wis, 3), 
                             inv.items.colorizeStat(luck, 3), inv.items.colorizeStat(str, 3),
                             inv.items.colorizeStat(dex, 3), inv.items.colorizeStat(con, 3)) 
    if (channel ~= nil) then
      inv.items.reportItem(channel,
                           colorName, level, typeExtended,
                           { { To = formattedLeadsTo },
                             { DR = dam }, { HR = hit }, 
                             { Wgt = weight },
                             { Str = str }, { Int = int }, { Wis = wis },
                             { Dex = dex }, { Con = con }, { Lck = luck }
                           })
    end -- if

  elseif (typeField == invmon.typeStr[invmonTypeContainer]) then
    header = "@WLvl Name of " .. formattedType .. 
             "Type       HR   DR Int Wis Lck Str Dex Con Wght  Cap Hold Hvy #In Wgt%@w"

    statLine = string.format("@W%3d@w %s%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s",
                             level, formattedName, typeExtended,
                             inv.items.colorizeStat(hit, 4), inv.items.colorizeStat(dam, 4), 
                             inv.items.colorizeStat(int, 3), inv.items.colorizeStat(wis, 3),
                             inv.items.colorizeStat(luck, 3), inv.items.colorizeStat(str, 3),
                             inv.items.colorizeStat(dex, 3), inv.items.colorizeStat(con, 3), 
                             inv.items.colorizeStat(totWeight, 4, true), inv.items.colorizeStat(capacity, 4),
                             inv.items.colorizeStat(holding, 4), inv.items.colorizeStat(heaviestItem, 3),
                             inv.items.colorizeStat(itemsInside, 3), inv.items.colorizeStat(weightReduction, 4))

    if (channel ~= nil) then
      inv.items.reportItem(channel,
                           colorName, level, typeExtended,
                           { { Capacity = capacity }, { WgtPct = weightReduction },
                             { DR = dam }, { HR = hit }, 
                             { Str = str }, { Int = int }, { Wis = wis },
                             { Dex = dex }, { Con = con }, { Lck = luck }
                           })
    end -- if


  elseif (typeField == invmon.typeStr[invmonTypeWeapon]) then
    header = "@WLvl Name of " .. formattedType ..
             "Type     Ave Wgt   HR   DR Dam Type Specials Int Wis Lck Str Dex Con@w"
    statLine = string.format("@W%3d@w %s%s %s %s %s %s %-8s %-8s %s %s %s %s %s %s",
                             level, formattedName, typeExtended,
                             inv.items.colorizeStat(avedam, 3), inv.items.colorizeStat(weight, 3),
                             inv.items.colorizeStat(hit, 4), inv.items.colorizeStat(dam, 4), 
                             damtype, specials,
                             inv.items.colorizeStat(int, 3), inv.items.colorizeStat(wis, 3),
                             inv.items.colorizeStat(luck, 3), inv.items.colorizeStat(str, 3),
                             inv.items.colorizeStat(dex, 3), inv.items.colorizeStat(con, 3))

    if (channel ~= nil) then
      inv.items.reportItem(channel,
                           colorName, level, typeExtended,
                           { { Ave = avedam }, { DR = dam }, { HR = hit }, 
                             { Wgt = weight }, 
                             { Str = str }, { Int = int }, { Wis = wis },
                             { Dex = dex }, { Con = con }, { Lck = luck },
                             { Dam = damtype }, { Special = specials },
                           })
    end -- if

  elseif (typeField == "Unknown") then
    header = "@WLvl Name of Unknown Item     Type"
    statLine = string.format("@WN/A@w %sItem has not yet been identified", formattedName)

  else
    header = "@WLvl Name of " .. formattedType .. 
             "Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move@w"

    statLine = string.format("@W%3d@w %s%s %s %s %s %s %s %s %s %s %s %s %s %s",
                             level, formattedName, typeExtended,
                             inv.items.colorizeStat(hit, 4), inv.items.colorizeStat(dam, 4), 
                             inv.items.colorizeStat(int, 3), inv.items.colorizeStat(wis, 3),
                             inv.items.colorizeStat(luck, 3), inv.items.colorizeStat(str, 3),
                             inv.items.colorizeStat(dex, 3), inv.items.colorizeStat(con, 3), 
                             inv.items.colorizeStat(totResists, 3),
                             inv.items.colorizeStat(hp, 4), inv.items.colorizeStat(mana, 4),
                             inv.items.colorizeStat(moves, 4)) 

    if (channel ~= nil) then
      inv.items.reportItem(channel,
                           colorName, level, typeExtended,
                           { { DR = dam }, { HR = hit }, 
                             { Str = str }, { Int = int }, { Wis = wis },
                             { Dex = dex }, { Con = con }, { Lck = luck },
                             { Res = totResists }, { HP = hp }, { MN = mana }, { MV = moves }
                           })
    end -- if
  end -- if

  -- Dump the stats for this item.  We print a header if we are in full verbosity mode or if this
  -- is the first item of its type to be displayed.
  if (channel == nil) then
    if (inv.items.displayLastType ~= typeField) or (verbosity == invDisplayVerbosityFull) then
      dbot.print("\n" .. header)
      inv.items.displayLastType = typeField
    end -- if
    dbot.print(statLine)
  end -- if

  -- Return now if the user requested anything except the full view -- everything has been displayed for those
  if (verbosity ~= invDisplayVerbosityFull) then
    return DRL_RET_SUCCESS
  end -- if

  local score = dbot.tonumber(inv.items.getStatField(objId, invStatFieldScore) or "0")
  local worth = dbot.tonumber(inv.items.getStatField(objId, invStatFieldWorth) or "0")
  local keywords = inv.items.getStatField(objId, invStatFieldKeywords) or ""
  local flags = inv.items.getStatField(objId, invStatFieldFlags) or ""
  local material = inv.items.getStatField(objId, invStatFieldMaterial) or ""
  local foundAt = inv.items.getStatField(objId, invStatFieldFoundAt) or ""
  local ownedBy = inv.items.getStatField(objId, invStatFieldOwnedBy) or ""
  local clan = inv.items.getStatField(objId, invStatFieldClan) or ""
  local affectMods = inv.items.getStatField(objId, invStatFieldAffectMods) or ""
  local organize = inv.items.getStatField(objId, invQueryKeyOrganize) or ""
  local inflicts = inv.items.getStatField(objId, invStatFieldInflicts) or ""

  -- Helper: format a stat as "+N" or "-N", returns nil if zero
  local function fmtStat(name, value)
    if (value == nil) or (value == 0) then return nil end
    if (value > 0) then return name .. " +" .. value end
    return name .. " " .. value
  end -- fmtStat

  -- Helper: collect non-nil entries into a comma-separated string
  local function joinParts(parts)
    local filtered = {}
    for _, v in ipairs(parts) do
      if (v ~= nil) then table.insert(filtered, v) end
    end -- for
    return table.concat(filtered, ", ")
  end -- joinParts

  -- 1. Name
  dbot.print("    @WName@w: " .. colorName .. " @w(" .. objId .. ")")

  -- 2. Keywords
  dbot.print("    @WKeywords@w: " .. keywords)

  -- 3. Type / Level / Weight / Score
  local typeDisplay = typeField
  if (typeField == invmon.typeStr[invmonTypeWeapon]) then
    typeDisplay = typeField .. " (" .. weaponType .. ")"
  elseif (typeField == invmon.typeStr[invmonTypeContainer]) then
    typeDisplay = "Container"
  end -- if
  dbot.print("    @WType@w: " .. typeDisplay .. "  @WLevel@w: " .. level ..
             "  @WWeight@w: " .. weight .. "  @WScore@w: " .. score)

  -- 4. Flags (only if non-empty)
  if (flags ~= "") then
    dbot.print("    @WFlags@w: " .. flags)
  end -- if

  -- 5. Type-specific line
  if (typeField == invmon.typeStr[invmonTypeWeapon]) then
    local weaponParts = { "Ave " .. avedam, damtype }
    if (inflicts ~= "") then
      table.insert(weaponParts, "Inflicts " .. inflicts)
    end -- if
    if (hit ~= 0) then table.insert(weaponParts, "HR " .. string.format("%+d", hit)) end
    if (dam ~= 0) then table.insert(weaponParts, "DR " .. string.format("%+d", dam)) end
    if (specials ~= "none") and (specials ~= "") then
      table.insert(weaponParts, "Specials: " .. specials)
    end -- if
    dbot.print("    @WWeapon@w: " .. table.concat(weaponParts, ", "))

  elseif (typeField == invmon.typeStr[invmonTypeContainer]) then
    dbot.print("    @WContainer@w: Cap " .. capacity .. ", Hold " .. holding ..
               ", Heaviest " .. heaviestItem .. ", Items " .. itemsInside ..
               ", Weight " .. totWeight .. ", WgtPct " .. weightReduction .. "%")

  elseif (typeField == invmon.typeStr[invmonTypePortal]) then
    dbot.print("    @WPortal@w: Leads to " .. leadsTo)

  elseif (typeField == invmon.typeStr[invmonTypePotion]) or
         (typeField == invmon.typeStr[invmonTypePill]) or
         (typeField == invmon.typeStr[invmonTypeScroll]) then
    local spellParts = {}
    for _, v in ipairs(spells) do
      table.insert(spellParts, "L" .. v.level .. " x" .. v.count .. " " .. v.name)
    end -- for
    if (#spellParts > 0) then
      dbot.print("    @WSpells@w: " .. table.concat(spellParts, ", "))
    end -- if

  elseif (typeField == invmon.typeStr[invmonTypeWand]) or
         (typeField == invmon.typeStr[invmonTypeStaff]) then
    local spellParts = {}
    for _, v in ipairs(spells) do
      table.insert(spellParts, "L" .. v.level .. " " .. v.name)
    end -- for
    if (#spellParts > 0) then
      dbot.print("    @WSpells@w: " .. table.concat(spellParts, ", "))
    end -- if
  end -- if

  -- 6. Resist Mods (only non-zero)
  local resistsLine = joinParts({
    fmtStat("All Phys", allphys), fmtStat("All Magic", allmagic),
    fmtStat("Slash", slash), fmtStat("Pierce", pierce), fmtStat("Bash", bash),
    fmtStat("Acid", acid), fmtStat("Cold", cold), fmtStat("Energy", energy),
    fmtStat("Holy", holy), fmtStat("Electric", electric), fmtStat("Negative", negative),
    fmtStat("Shadow", shadow), fmtStat("Magic", magic),
    fmtStat("Air", air), fmtStat("Earth", earth), fmtStat("Fire", fire),
    fmtStat("Water", water), fmtStat("Light", light), fmtStat("Mental", mental),
    fmtStat("Sonic", sonic), fmtStat("Poison", poison), fmtStat("Disease", disease)
  })
  if (resistsLine ~= "") then
    dbot.print("    @WResists@w: " .. resistsLine)
  end -- if

  -- 7. Metadata (only non-empty fields)
  local metaParts = {}
  if (material ~= "") and (material ~= "Unknown") then
    table.insert(metaParts, "@WMaterial@w: " .. material)
  end -- if
  if (worth ~= 0) then
    table.insert(metaParts, "@WWorth@w: " .. worth)
  end -- if
  if (foundAt ~= "") and (foundAt ~= "Unknown") then
    table.insert(metaParts, "@WFound@w: " .. foundAt)
  end -- if
  if (ownedBy ~= "") then
    table.insert(metaParts, "@WOwner@w: " .. ownedBy)
  end -- if
  if (#metaParts > 0) then
    dbot.print("    " .. table.concat(metaParts, "  "))
  end -- if

  -- 8. Organize query (only if set)
  if (organize ~= "") then
    dbot.print("    @WOrganize@w: " .. organize)
  end -- if

  -- 9. Affect mods (only if non-empty)
  if (affectMods ~= "") then
    dbot.print("    @WAffects@w: " .. affectMods)
  end -- if

  -- 10. Clan (only if non-empty)
  if (clan ~= "") then
    dbot.print("    @WClan@w: " .. clan)
  end -- if

  return DRL_RET_SUCCESS
end -- inv.items.displayItem


function inv.items.colorizeStat(value, numDigits, invertColors)

  if (numDigits == nil) then
    dbot.error("inv.items.colorizeStat: Invalid nil numDigits parameter detected")
    return nil, DRL_RET_INTERNAL_ERROR
  end -- if

  if (value == nil) then
    value = 0
  end -- if

  local prefix = ""
  local suffix = ""

  value = tonumber(value)
  numDigits = tonumber(numDigits)

  if (value == nil) or (numDigits == nil) then
    dbot.warn("inv.items.colorizeStat: non-numeric parameter detected: value=\"" .. (value or "nil") .. 
            "\", numDigits=\"" .. (numDigits or "nil") .. "\"")
    return nil
  end -- if

  invertColors = invertColors or false

  if ((value < 0) and (invertColors == false)) or ((value > 0) and (invertColors == true)) then
    prefix = DRL_ANSI_RED
    suffix = DRL_ANSI_WHITE
  elseif ((value > 0) and (invertColors == false)) or ((value < 0) and (invertColors == true)) then
    prefix = DRL_ANSI_GREEN
    suffix = DRL_ANSI_WHITE
  end -- if

  return string.format(prefix .. "%" .. numDigits .. "d" .. suffix, value)
end -- inv.items.colorizeStat


function inv.items.isInvis(objId)
  local flags = inv.items.getStatField(objId, invStatFieldFlags) or ""

  if dbot.isWordInString("invis", flags) or dbot.isWordInString("invis,", flags) then
    return true
  else
    return false
  end -- if
end -- inv.items.isInvis


----------------------------------------------------------------------------------------------------
--
-- Module to organize inventory items into containers based on queries assigned to containers
--
-- Each container may optionally have a set of item queries assigned to it.  If we "organize" an
-- item that matches a query on a container, we move that item to the associated container.  For
-- example, we might assign a container a query like "type Key || flag isKey" and then we can
-- automagically organize it to move all keys into the container.  We could do similar things to
-- put all portals together into a container or all potions together.  We can even use more
-- complicated queries that would put items of particular types and levels together.
--
-- Note: If an item matches queries on multiple containers, there currently is no way to specify
--       container priorities and the item could end up in any matching container.  For now, it is
--       up to the user to not create conflicting container queries.
-- TODO: Check if there is any overlap in the item arrays returned from container queries and
--       warn the user.  We could also implement a priority scheme for containers too, but that 
--       seems like overkill...
--
-- dinv organize [add | clear] <container relative name> <query>
-- dinv organize [display]
-- dinv organize <query>
--
-- inv.items.organize.add(containerName, queryString, endTag)
-- inv.items.organize.addCR() 
-- inv.items.organize.clear(containerName, endTag)
-- inv.items.organize.clearCR()
-- inv.items.organize.display(endTag)
-- inv.items.organize.getTargets()
--
-- inv.items.organize.cleanup(queryString, endTag)
-- inv.items.organize.cleanupCR()
--
----------------------------------------------------------------------------------------------------

inv.items.organize = {}


inv.items.organize.addPkg = nil
function inv.items.organize.add(containerName, queryString, endTag) 
  if (containerName == nil) or (containerName == "") then
    dbot.warn("inv.items.organize.add: Missing container relative name")
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  -- We allow users to organize their entire inventory in one shot with an empty string that matches
  -- everything.  However, we do NOT allow a single container to own everything by giving a container
  -- an empty organization query string.  That almost certainly was not what the user intended.
  if (queryString == nil) or (queryString == "") then
    dbot.warn("inv.items.organize.add: Containers are not allowed to own all possible items (empty query)")
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.items.organize.addPkg ~= nil) then
    dbot.info("Skipping add request in organize package: another add request is in progress")
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_BUSY)    
  end -- if

  inv.items.organize.addPkg           = {}
  inv.items.organize.addPkg.container = containerName
  inv.items.organize.addPkg.query     = queryString
  inv.items.organize.addPkg.endTag    = endTag
  
  wait.make(inv.items.organize.addCR)

  return DRL_RET_SUCCESS
end -- inv.items.organize.add


function inv.items.organize.addCR() 
  local retval
  local objId
  local idArray

  if (inv.items.organize.addPkg == nil) then
    dbot.error("inv.items.organize.addCR: addPkg is nil!")
    return inv.tags.stop(invTagsOrganize, "nil end tag", DRL_RET_INTERNAL_ERROR)
  end -- if

  -- Find the unique container specified by the user via a relative name (e.g., "2.bag")
  idArray, retval = inv.items.searchCR("type container rname " .. inv.items.organize.addPkg.container)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.organize.addCR: failed to search inventory table: " .. dbot.retval.getString(retval))
  elseif (#idArray ~= 1) then
    -- There should only be a single match to the container's relative name (e.g., "2.bag")
    dbot.warn("Container relative name \"" .. inv.items.organize.addPkg.container .. 
              "\" did not have a unique match for a container: skipping organization query request")
  else
    -- We found a single unique match for the relative name
    objId = idArray[1]
  end -- if

  local endTag = inv.items.organize.addPkg.endTag

  -- Handle the error case where we couldn't find a matching container
  if (objId == nil) then
    inv.items.organize.addPkg = nil
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  -- We have the container and a query for the container.  Append the query to any previous organization
  -- queries for that container.
  local organizeField = inv.items.getStatField(objId, invQueryKeyOrganize) or ""
  if (organizeField ~= "") then
    organizeField = organizeField .. " || "  -- on 2nd and subsequent queries, use the OR operator
  end -- if
  organizeField = organizeField .. inv.items.organize.addPkg.query
  inv.items.setStatField(objId, invQueryKeyOrganize, organizeField)
  dinv_db.saveItem(objId, inv.items.table[objId])

  -- Add the new organization query to the custom cache
  retval = inv.cache.add(inv.cache.custom.table, objId)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.organize.addCR: Failed to add organize queries to custom cache for object " ..
              objId .. dbot.retval.getString(retval))
  end -- if
  inv.cache.saveCustom()

  dbot.info("Added organization query \"@C" .. inv.items.organize.addPkg.query .. "@W\" to container \"" ..
            (inv.items.getField(objId, invFieldColorName) or "Unidentified"))

  -- Clean up, print an end tag (if necessary), and return
  inv.items.organize.addPkg = nil
  return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_SUCCESS)
end -- inv.items.organize.addCR


inv.items.organize.clearPkg = nil
function inv.items.organize.clear(containerName, endTag)
  if (containerName == nil) or (containerName == "") then
    dbot.warn("inv.items.organize.clear: Missing container relative name")
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.items.organize.clearPkg ~= nil) then
    dbot.info("Skipping clear request in organize package: another clear request is in progress")
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_BUSY)    
  end -- if

  inv.items.organize.clearPkg           = {}
  inv.items.organize.clearPkg.container = containerName
  inv.items.organize.clearPkg.endTag    = endTag
  
  wait.make(inv.items.organize.clearCR)

  return DRL_RET_SUCCESS
end -- inv.items.organize.clear


function inv.items.organize.clearCR()
  local retval
  local objId
  local idArray

  if (inv.items.organize.clearPkg == nil) then
    dbot.error("inv.items.organize.clearCR: clearPkg is nil!")
    return inv.tags.stop(invTagsOrganize, "nil end tag", DRL_RET_INTERNAL_ERROR)
  end -- if

  -- Find the unique container specified by the user via a relative name (e.g., "2.bag")
  idArray, retval = inv.items.searchCR("type container rname " .. inv.items.organize.clearPkg.container)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.organize.clearCR: failed to search inventory table: " ..
              dbot.retval.getString(retval))
  elseif (#idArray ~= 1) then
    -- There should only be a single match to the container's relative name (e.g., "2.bag")
    dbot.warn("Container relative name \"" .. inv.items.organize.clearPkg.container .. 
              "\" did not have a unique match for a container: skipping organization query request")
  else
    -- We found a single unique match for the relative name
    objId = idArray[1]
  end -- if

  local endTag = inv.items.organize.clearPkg.endTag

  -- Handle the error case where we couldn't find a matching container
  if (objId == nil) then
    inv.items.organize.clearPkg = nil
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  -- We have the container.  Whack it!
  inv.items.setStatField(objId, invQueryKeyOrganize, "")
  dinv_db.saveItem(objId, inv.items.table[objId])

  -- Update the custom cache because organization queries are stored there long term
  retval = inv.cache.add(inv.cache.custom.table, objId)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.organize.clearCR: Failed to add organize queries to custom cache for object " ..
              objId .. dbot.retval.getString(retval))
  end -- if
  inv.cache.saveCustom()

  dbot.info("Cleared all organization queries from container \"" ..
            (inv.items.getField(objId, invFieldColorName) or "Unidentified") .. DRL_ANSI_WHITE .. "@W\"")

  -- Clean up, print an end tag (if necessary) and return
  inv.items.organize.clearPkg = nil
  return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_SUCCESS)
end -- inv.items.organize.clearCR


function inv.items.organize.display(endTag)
  local foundContainerWithQuery = false
  local retval = DRL_RET_SUCCESS

  dbot.print("@WContainers that have associated organizational queries:@w")

  for objId, _ in pairs(inv.items.table) do
    local organizeQuery = inv.items.getStatField(objId, invQueryKeyOrganize) or ""
    if (organizeQuery ~= "") then
      dbot.print("@W  " .. (inv.items.getField(objId, invFieldColorName) or "Unidentified") ..
                 DRL_ANSI_WHITE .. "@W (" .. objId .. "): @C" .. organizeQuery .. "@w")
      foundContainerWithQuery = true
    end -- if
  end -- for

  if (foundContainerWithQuery == false) then
    dbot.print("@W  No containers with organizational queries were found")
    retval = DRL_RET_MISSING_ENTRY
  end -- if

  return inv.tags.stop(invTagsOrganize, endTag, retval)
end -- inv.items.organize.display


-- Build a lookup table mapping item objIds to their target container objId
-- based on organize rules.  For each container with an organize query, run
-- the query and record the first matching container for each matched item.
-- Returns: table { [itemObjId] = containerObjId, ... }
function inv.items.organize.getTargets()
  local targets = {}

  for objId, _ in pairs(inv.items.table) do
    local organizeQuery = inv.items.getStatField(objId, invQueryKeyOrganize) or ""
    if (organizeQuery ~= "") then
      local matchedIds, retval = inv.items.searchCR(organizeQuery)
      if (retval == DRL_RET_SUCCESS) and (matchedIds ~= nil) then
        for _, matchedId in ipairs(matchedIds) do
          -- Don't assign containers as targets of organize rules
          if (inv.items.getStatField(matchedId, invStatFieldType) ~= invmon.typeStr[invmonTypeContainer]) then
            if not targets[matchedId] then
              targets[matchedId] = objId  -- first match wins
            end -- if
          end -- if
        end -- for
      end -- if
    end -- if
  end -- for

  return targets
end -- inv.items.organize.getTargets


inv.items.organize.cleanupPkg = nil
function inv.items.organize.cleanup(queryString, endTag)

  if (inv.items.organize.cleanupPkg ~= nil) then
    dbot.info("Skipping request to organize inventory: another request is in progress")
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_BUSY)
  end -- if

  inv.items.organize.cleanupPkg        = {}
  inv.items.organize.cleanupPkg.query  = queryString
  inv.items.organize.cleanupPkg.endTag = endTag

  wait.make(inv.items.organize.cleanupCR)

  return DRL_RET_SUCCESS
end -- inv.items.organize.cleanup


function inv.items.organize.cleanupCR()
  local invIdArray
  local retval

  if (inv.items.organize.cleanupPkg == nil) then
    dbot.error("inv.items.organize.cleanupCR: cleanupPkg is nil!")
    return inv.tags.stop(invTagsOrganize, "nil end tag", DRL_RET_INTERNAL_ERROR)
  end -- if

  local endTag = inv.items.organize.cleanupPkg.endTag

  -- Track how many items we move due to organization.  It's handy to report this when we're done.
  local numItemsOrganized = 0

  -- Find all items that match the given inventory query
  invIdArray, retval = inv.items.searchCR(inv.items.organize.cleanupPkg.query)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.items.organize.cleanupCR: failed to search inventory table: " .. 
              dbot.retval.getString(retval))
    inv.items.organize.cleanupPkg = nil
    return inv.tags.stop(invTagsOrganize, endTag, retval)
  end -- if

  -- Pre-scan: detect items that match organize queries for multiple containers and warn the user
  local itemToContainers = {}  -- itemId → { {containerId, containerName, query}, ... }
  for objId, _ in pairs(inv.items.table) do
    local organizeQuery = inv.items.getStatField(objId, invQueryKeyOrganize) or ""
    if (organizeQuery ~= "") then
      local containerIdArray, scanRetval = inv.items.searchCR(organizeQuery)
      if (scanRetval == DRL_RET_SUCCESS) then
        local containerName = inv.items.getField(objId, invFieldColorName) or "Unknown"
        for _, invId in ipairs(invIdArray) do
          for _, containerId in ipairs(containerIdArray) do
            if (invId == containerId) and
               (inv.items.getStatField(invId, invStatFieldType) ~= invmon.typeStr[invmonTypeContainer]) then
              if not itemToContainers[invId] then
                itemToContainers[invId] = {}
              end
              table.insert(itemToContainers[invId], {
                containerId = objId,
                containerName = containerName,
                query = organizeQuery,
              })
            end
          end
        end
      end
    end
  end

  for itemId, containers in pairs(itemToContainers) do
    if #containers > 1 then
      local itemName = inv.items.getField(itemId, invFieldColorName) or "Unknown"
      dbot.warn("Item \"" .. itemName .. "@W\" matches organize queries for multiple containers:")
      for _, c in ipairs(containers) do
        dbot.print("  \"" .. c.containerName .. "@W\" (" .. c.query .. ")")
      end
    end
  end

  -- For each container that has an organization query associated with it, find all items that
  -- match that query.  Any item that appears in both the container's ID array and the inventory
  -- ID array belongs to the container and should be moved there.
  for objId, _ in pairs(inv.items.table) do
    local organizeQuery = inv.items.getStatField(objId, invQueryKeyOrganize) or ""
    if (organizeQuery ~= "") then
      local containerIdArray, retval = inv.items.searchCR(organizeQuery)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.items.organize.cleanupCR: failed to search inventory table: " .. 
                  dbot.retval.getString(retval))
        inv.items.organize.cleanupPkg = nil
        return inv.tags.stop(invTagsOrganize, endTag, retval)
      end -- if

      local commandArray = dbot.execute.new()

      -- This n^2 algorithm isn't efficient, but I don't think the speed is an issue for us
      for _, invId in ipairs(invIdArray) do
        for _, containerId in ipairs(containerIdArray) do
          -- Note that we don't want to try sorting containers into other containers
          if (invId == containerId) and 
             (inv.items.getStatField(invId, invStatFieldType) ~= invmon.typeStr[invmonTypeContainer]) then
            dbot.debug("Found item to organize: \"" .. 
                       (inv.items.getField(invId, invFieldColorName) or "Unidentified") ..
                       DRL_ANSI_WHITE .. "@W\"")

            -- If the item isn't already in the container, move it there
            local itemLoc = inv.items.getField(invId, invFieldObjLoc)
            if (itemLoc ~= nil) and (itemLoc ~= "") and (itemLoc ~= objId) then
              retval = inv.items.putItem(invId, objId, commandArray, true)
              if (retval ~= DRL_RET_SUCCESS) then
                dbot.debug("inv.items.organize.cleanupCR: failed to put item \"" ..
                           (inv.items.getField(invId, invFieldColorName) or "Unidentified") .. 
                           "\" in container \"" ..
                           (inv.items.getField(objId, invFieldColorName) or "Unidentified") .. "\": " ..
                           dbot.retval.getString(retval))
                break
              else
                numItemsOrganized = numItemsOrganized + 1
              end -- if

              if (commandArray ~= nil) and (#commandArray >= inv.items.burstSize) then
                retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
                if (retval ~= DRL_RET_SUCCESS) then
                  dbot.info("Skipping request to organize items: " .. dbot.retval.getString(retval))
                  break
                end -- if
                commandArray = dbot.execute.new()
              end -- if

            end -- if          
          end -- if
        end -- for
      end -- for

      -- Flush any commands in the array that still need to be sent to the mud
      if (retval == DRL_RET_SUCCESS) and (commandArray ~= nil) then
        retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.info("Skipping request to get items: " .. dbot.retval.getString(retval))
          break
        end -- if
      end -- if

      if dbot.gmcp.statePreventsActions() then
        dbot.info("Skipping organize request: character's state does not allow actions")
        retval = DRL_RET_NOT_ACTIVE
        break
      end -- if
    end -- if
  end -- for

  -- Report the results
  if (retval == DRL_RET_SUCCESS) then
    local suffix = ""
    if (numItemsOrganized ~= 1) then
      suffix = "s"
    end -- if
    dbot.info("Organized " .. numItemsOrganized .. " item" .. suffix .. " matching query \"@C" ..
              inv.items.organize.cleanupPkg.query .. "@W\"")
  end -- if

  -- Clean up the function, print an end tag (if necessary), and return
  inv.items.organize.cleanupPkg = nil
  return inv.tags.stop(invTagsOrganize, endTag, retval)
end -- inv.items.organize.cleanupCR


----------------------------------------------------------------------------------------------------
-- inv.items.trigger: Trigger functions for the inv.items module
--
-- Functions:
--
--   Get or put items
--     inv.items.trigger.get
--     inv.items.trigger.put
--     inv.items.trigger.getKeyring
--     inv.items.trigger.putKeyring
--
--   Wear or remove items
--     inv.items.trigger.wear
--     inv.items.trigger.remove
--
--   Parses identify, auction, or shop items
--     inv.items.trigger.itemIdStart
--     inv.items.trigger.itemIdStats
--     inv.items.trigger.itemIdEnd
--
--   Quick and dirty parse of item to get the item's object ID
--     inv.items.trigger.idItem
--
--   Parses eqdata, invdata, keyring data; itemDataStats is also re-used to handle invitem
--     inv.items.trigger.itemDataStart
--     inv.items.trigger.itemDataStats
--     inv.items.trigger.itemDataEnd
--
--   Parse invmon output
--     inv.items.trigger.invmon
--
----------------------------------------------------------------------------------------------------

inv.items.trigger = {}

inv.items.trigger.wearSpecialName = "drlInvItemsTriggerWearSpecial"
inv.items.trigger.wearName        = "drlInvItemsTriggerWear"
inv.items.trigger.removeName      = "drlInvItemsTriggerRemove"

inv.items.trigger.getName         = "drlInvItemsTriggerGet"
inv.items.trigger.putName         = "drlInvItemsTriggerPut"
inv.items.trigger.getKeyringName  = "drlInvItemsTriggerGetKeyring"
inv.items.trigger.putKeyringName  = "drlInvItemsTriggerPutKeyring"

inv.items.trigger.itemIdStartName = "drlInvItemsTriggerIdStart"
inv.items.trigger.itemIdStatsName = "drlInvItemsTriggerIdStats"
inv.items.trigger.itemIdEndName   = "drlInvItemsTriggerIdEnd"

inv.items.trigger.suppressWindsName = "drlInvItemsTriggerSuppressWindsCase" -- Winds of Fate epic container

inv.items.trigger.suppressIdMsgName = "drlInvItemsTriggerSuppressIdMsg" -- suppress output for lore, etc.


function inv.items.trigger.wear(line)
  if (line ~= nil) and (line ~= "") then
    dbot.debug("Triggered \"wear\" output on: " .. line)

    if (string.find(line, "You do not have that item")) then
      dbot.debug("inv.items.trigger.wear: Failed to wear item: You do not have that item.")
    end -- if
  end -- if
end -- inv.items.trigger.wear


function inv.items.trigger.remove(line)
  if (line ~= nil) and (line ~= "") then
    dbot.debug("Triggered \"remove\" output on: " .. line)

    if (string.find(line, "You are not wearing that item")) then
      dbot.debug("inv.items.trigger.wear: Failed to wear item: You are not wearing that item.")
    end -- if
  end -- if
end -- inv.items.trigger.remove


function inv.items.trigger.get(line)
  if (line ~= nil) and (line ~= "") then
    dbot.debug("Triggered \"get\" output on: " .. line)

    if (string.find(line, "You do not see")) then
      dbot.debug("inv.items.trigger.get: Failed to get item")
    end -- if
  end -- if
end -- inv.items.trigger.get


function inv.items.trigger.put(line)
  if (line ~= nil) and (line ~= "") then
    dbot.debug("Triggered \"put\" output on: " .. line)

    if (string.find(line, "You don't have that")) then
      dbot.debug("inv.items.trigger.put: Failed to put item because it is not in your inventory.")
    elseif (string.find(line, "You do not see")) then
      dbot.debug("inv.items.trigger.put: Failed to put item because the container is not in your inventory.")
    end -- if
  end -- if
end -- inv.items.trigger.put


function inv.items.trigger.getKeyring(line)
  if (line ~= nil) and (line ~= "") then
    dbot.debug("Triggered \"keyring get\" output on: " .. line)
    local errMsg = "You did not find that"
    if (string.find(line, errMsg)) then
      dbot.debug("inv.items.trigger.getKeyring: Failed to get keyring item: " .. errMsg)
    end -- if
  end -- if
end -- inv.items.trigger.getKeyring


function inv.items.trigger.putKeyring(line)
  if (line ~= nil) and (line ~= "") then
    dbot.debug("Triggered \"keyring put\" output on: " .. line)
    local errMsg = "You do not have that item"
    if (string.find(line, errMsg)) then
      dbot.debug("inv.items.trigger.putKeyring: Failed to put keyring item: " .. errMsg)
    end -- if
  end -- if
end -- inv.items.trigger.putKeyring


function inv.items.trigger.itemIdStart(line)

  if (line == "You do not have that item.") or
    string.find(line, "currently holds no inventory") or
    string.find(line, "There is no auction item with that id") or
    string.find(line, "There is no marketplace item with that id") or
    string.find(line, "does not have that item for sale") then
    inv.items.trigger.itemIdEnd()
    return DRL_RET_MISSING_ENTRY
  end -- if

  if (inv.items.identifyPkg == nil) then
    return DRL_RET_INTERNAL_ERROR
  end -- if

  -- Clear the ID level field.  If we detect a partial identification this time, we
  -- flag the item as having a partial ID.  If we don't detect a partial identification,
  -- we flag it as having a full ID when we hit the end trigger.
  inv.items.setField(inv.items.identifyPkg.objId, invFieldIdentifyLevel, invIdLevelNone)

  -- Start watching for stat lines in the item description
  EnableTrigger(inv.items.trigger.itemIdStatsName, true)

  -- Watch for the end of the item description so that we can stop scanning
  AddTriggerEx(inv.items.trigger.itemIdEndName,
               "^" .. inv.items.identifyFence .. "$",
               "inv.items.trigger.itemIdEnd()",
               drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput + trigger_flag.OneShot,
               custom_colour.Custom11,
               0, "", "", sendto.script, 0)

  -- If the start trigger matched a content line (blindmode: no border lines),
  -- process it as the first stats line so we don't lose the data
  if string.find(line, "^| ") then
    inv.items.trigger.itemIdStats(line)
  end -- if
end -- inv.items.trigger.itemIdStart


inv.items.trigger.flagsContinuation      = false
inv.items.trigger.affectModsContinuation = false
inv.items.trigger.keywordsContinuation   = false
inv.items.trigger.nameContinuation       = false
function inv.items.trigger.itemIdStats(line)
  dbot.debug("stats for item " .. inv.items.identifyPkg.objId .. ":\"" .. line .. "\"")

  local isPartialId, id, name, level, weight, wearable, score, keywords, itemType, worth, flags,
        affectMods, continuation, material, foundAt, ownedBy, clan, rawMaterial

  isPartialId = string.find(line, "A full appraisal will reveal further information on this item")

  _, _, id = string.find(line, "Id%s+:%s+(%d+)%s+")
  _, _, name = string.find(line, "Name%s+:%s+(.-)%s*|$")
  _, _, level = string.find(line, "Level%s+:%s+(%d+)%s+")
  _, _, weight = string.find(line, "Weight%s+:%s+([0-9,-]+)%s+")
  _, _, wearable = string.find(line, "Wearable%s+:%s+(.*) %s+")
  _, _, score = string.find(line, "Score%s+:%s([0-9,]+)%s+")
  _, _, keywords = string.find(line, "Keywords%s+:%s+(.-)%s*|")
  _, _, itemType = string.find(line, "| Type%s+:%s+(%a+)%s+")
  _, _, rawMaterial = string.find(line, "| Type%s+:%s+(Raw material:%a+)")

  _, _, worth = string.find(line, "Worth%s+:%s+([0-9,]+)%s+")
  _, _, flags = string.find(line, "Flags%s+:%s+(.-)%s*|")
  _, _, affectMods = string.find(line, "Affect Mods:%s+(.-)%s*|")
  _, _, continuation = string.find(line, "|%s+:%s+(.-)%s*|")
  _, _, material = string.find(line, "Material%s+:%s+(.*)%s+")
  _, _, foundAt = string.find(line, "Found at%s+:%s+(.-)%s*|")
  _, _, ownedBy = string.find(line, "Owned By%s+:%s+(.-)%s*|")
  _, _, clan = string.find(line, "Clan Item%s+:%s+(.-)%s*|")

  -- Potions, pills, wands, and staves
  local spellUses, spellLevel, spellName
  _, _, spellUses, spellLevel, spellName = string.find(line, "([0-9]+) uses? of level ([0-9]+) '(.*)'")

  -- Portal-only fields
  local leadsTo
  _, _, leadsTo = string.find(line, "Leads to%s+:%s+(.*)%s+")

  -- Container-only fields
  local capacity, holding, heaviestItem, itemsInside, totWeight, itemBurden, weightReduction
  _, _, capacity = string.find(line, "Capacity%s+:%s+([0-9,]+)%s+")
  _, _, holding = string.find(line, "Holding%s+:%s+([0-9,]+)%s+")
  _, _, heaviestItem = string.find(line, "Heaviest Item:%s+([0-9,]+)%s+")
  _, _, itemsInside = string.find(line, "Items Inside%s+:%s+([0-9,]+)%s+")
  _, _, totWeight = string.find(line, "Tot Weight%s+:%s+([0-9,-]+)%s+")
  _, _, itemBurden = string.find(line, "Item Burden%s+:%s+([0-9,]+)%s+")
  _, _, weightReduction = string.find(line, "Items inside weigh (%d+). of their usual weight%s+")

  local int, wis, luck, str, dex, con
  _, _, int = string.find(line, "Intelligence%s+:%s+([+-]?%d+)%s+")
  _, _, wis = string.find(line, "Wisdom%s+:%s+([+-]?%d+)%s+")
  _, _, luck = string.find(line, "Luck%s+:%s+([+-]?%d+)%s+")
  _, _, str = string.find(line, "Strength%s+:%s+([+-]?%d+)%s+")
  _, _, dex = string.find(line, "Dexterity%s+:%s+([+-]?%d+)%s+")
  _, _, con = string.find(line, "Constitution%s+:%s+([+-]?%d+)%s+")

  local hp, mana, moves
  _, _, hp = string.find(line, "Hit points%s+:%s+([+-]?%d+)%s+")
  _, _, mana = string.find(line, "Mana%s+:%s+([+-]?%d+)%s+")
  _, _, moves = string.find(line, "Moves%s+:%s+([+-]?%d+)%s+")

  local hit, dam
  _, _, hit = string.find(line, "Hit roll%s+:%s+([+-]?%d+)%s+")
  _, _, dam = string.find(line, "Damage roll%s+:%s+([+-]?%d+)%s+")

  local allphys, allmagic
  _, _, allphys = string.find(line, "All physical%s+:%s+([+-]?%d+)%s+")
  _, _, allmagic = string.find(line, "All magic%s+:%s+([+-]?%d+)%s+")

  local acid, cold, energy, holy, electric, negative, shadow, magic, air, earth, fire, light, mental,
        sonic, water, poison, disease
  _, _, acid = string.find(line, "Acid%s+:%s+([+-]?%d+)%s+")
  _, _, cold = string.find(line, "Cold%s+:%s+([+-]?%d+)%s+")
  _, _, energy = string.find(line, "Energy%s+:%s+([+-]?%d+)%s+")
  _, _, holy = string.find(line, "Holy%s+:%s+([+-]?%d+)%s+")
  _, _, electric = string.find(line, "Electric%s+:%s+([+-]?%d+)%s+")
  _, _, negative = string.find(line, "Negative%s+:%s+([+-]?%d+)%s+")
  _, _, shadow = string.find(line, "Shadow%s+:%s+([+-]?%d+)%s+")
  _, _, magic = string.find(line, "Magic%s+:%s+([+-]?%d+)%s+")
  _, _, air = string.find(line, "Air%s+:%s+([+-]?%d+)%s+")
  _, _, earth = string.find(line, "Earth%s+:%s+([+-]?%d+)%s+")
  _, _, fire = string.find(line, "Fire%s+:%s+([+-]?%d+)%s+")
  _, _, light = string.find(line, "Light%s+:%s+([+-]?%d+)%s+")
  _, _, mental = string.find(line, "Mental%s+:%s+([+-]?%d+)%s+")
  _, _, sonic = string.find(line, "Sonic%s+:%s+([+-]?%d+)%s+")
  _, _, water = string.find(line, "Water%s+:%s+([+-]?%d+)%s+")
  _, _, poison = string.find(line, "Poison%s+:%s+([+-]?%d+)%s+")
  _, _, disease = string.find(line, "Disease%s+:%s+([+-]?%d+)%s+")

  local slash, pierce, bash
  _, _, slash = string.find(line, "Slash%s+:%s+([+-]?%d+)%s+")
  _, _, pierce = string.find(line, "Pierce%s+:%s+([+-]?%d+)%s+")
  _, _, bash = string.find(line, "Bash%s+:%s+([+-]?%d+)%s+")

  local avedam, inflicts, damtype, weaponType, specials
  _, _, avedam = string.find(line, "Average Dam%s+:%s+(%d+)%s+")
  _, _, inflicts = string.find(line, "Inflicts%s+:%s+(%a+)%s+")
  _, _, damtype = string.find(line, "Damage Type%s+:%s+(%a+)%s+")
  _, _, weaponType = string.find(line, "Weapon Type:%s+(%a+)%s+")
  _, _, specials = string.find(line, "Specials%s+:%s+(%a+)%s+")

  local tmpAvedam, tmpHR, tmpDR, tmpInt, tmpWis, tmpLuck, tmpStr, tmpDex, tmpCon
  _, _, tmpAvedam = string.find(line, ":%s+adds [+-](%d+) average damage%s+")
  _, _, tmpHR = string.find(line, ":%s+hit roll [+-](%d+)")
  _, _, tmpDR = string.find(line, ":%s+damage roll [+-](%d+)")
  _, _, tmpInt = string.find(line, ":%s+intelligence [+-](%d+)")
  _, _, tmpWis = string.find(line, ":%s+wisdom [+-](%d+)")
  _, _, tmpLuck = string.find(line, ":%s+luck [+-](%d+)")
  _, _, tmpStr = string.find(line, ":%s+strength [+-](%d+)")
  _, _, tmpDex = string.find(line, ":%s+dexterity [+-](%d+)")
  _, _, tmpCon = string.find(line, ":%s+constitution [+-](%d+)")

  if (id ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldId, dbot.tonumber(id or ""))
    dbot.debug("Id = \"" .. id .. "\"")

    -- If we hit the id field, we know that there aren't any more name continuation lines
    inv.items.trigger.nameContinuation = false
  end -- if

  if (name ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldName, name)
    dbot.debug("Name = \"" .. name .. "\"")

    -- If we hit the name field, we know that there aren't any more keyword continuation lines.
    -- Instead we assume the name will continue until we hit the Id field.
    inv.items.trigger.keywordsContinuation = false
    inv.items.trigger.nameContinuation = true
  end -- if

  if (level ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldLevel, dbot.tonumber(level or ""))
    dbot.debug("Level = \"" .. level .. "\"")
  end -- if

  if (weight ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWeight, dbot.tonumber(weight or ""))
    dbot.debug("Weight = \"" .. weight .. "\"")
  end -- if

  if (wearable ~= nil) then
    -- Strip out spaces and commas for items that can have more than one wearable location (e.g., "hold, light")
    wearable = string.gsub(Trim(wearable), ",", "")

    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWearable, wearable)
    dbot.debug("Wearable = \"" .. wearable .. "\"")
  end -- if

  if (score ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldScore, dbot.tonumber(score or ""))
    dbot.debug("Score = \"" .. score .. "\"")
  end -- if

  if (keywords ~= nil) then
    -- Merge this with any previous keywords.  Someone may have added custom keywords to the
    -- item and then re-identified it for some reason.  For example, someone may have toggled the
    -- keep flag which would cause invitem to flag the item to be re-identified.
    local oldKeywords = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldKeywords) or ""
    local mergedKeywords = dbot.mergeFields(keywords, oldKeywords) or keywords

    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldKeywords, mergedKeywords)
    dbot.debug("Keywords = \"" .. mergedKeywords .. "\"")

    -- Assume that the keywords keep continuing on additional lines until we finally hit the name
    -- field.  At that point we know that there are no more keyword lines.
    inv.items.trigger.keywordsContinuation = true
  end -- if

  if (itemType ~= nil) or (rawMaterial ~= nil) then
    -- All item types, with the exception of "Raw material:[whatever]" are a single word.  As a
    -- result, we treat "Raw material" as a one-off and strip out the space for our internal use.
    if (rawMaterial ~= nil) then
      itemType = string.gsub(rawMaterial, "Raw material", "RawMaterial")
    end -- if

    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldType, itemType)
    dbot.debug("Type = \"" .. itemType .. "\"")
  end -- if

  if (worth ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWorth, dbot.tonumber(worth))
    dbot.debug("Worth = \"" .. worth .. "\"")
  end -- if

  if (isPartialId ~= nil) then
    inv.items.setField(inv.items.identifyPkg.objId, invFieldIdentifyLevel, invIdLevelPartial)
    dbot.debug("Id level = \"" .. invIdLevelPartial .. "\"")
  end -- if

  if (flags ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldFlags, flags)
    dbot.debug("Flags = \"" .. flags .. "\"")

    -- If the flags are continued (they end in a ",") watch for the continuation
    if (string.find(flags, ",$")) then
      inv.items.trigger.flagsContinuation = true
    else
      inv.items.trigger.flagsContinuation = false
    end -- if
  end -- if

  if (affectMods ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAffectMods, affectMods)
    dbot.debug("AffectMods = \"" .. affectMods .. "\"")

    -- If the affectMods are continued (they end in a ",") watch for the continuation
    if (string.find(affectMods, ",$")) then
      inv.items.trigger.affectModsContinuation = true
    else
      inv.items.trigger.affectModsContinuation = false
    end -- if
  end -- if

  if (continuation ~= nil) then
    dbot.debug("Continuation = \"" .. continuation .. "\"")
    if (inv.items.trigger.flagsContinuation) then
      -- Add the continuation to the existing flags
      inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldFlags,
                             (inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldFlags) or "") ..
                             " " .. continuation)

      -- If the continued flags end in a comma, keep the continuation going; otherwise stop it
      if not (string.find(continuation, ",$")) then
        inv.items.trigger.flagsContinuation = false
      end -- if

    elseif (inv.items.trigger.affectModsContinuation) then
      -- Add the continuation to the existing affectMods
      inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAffectMods,
                            (inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldAffectMods) 
                             or "") .. " " .. continuation)

      -- If the continued affectMods end in a comma, keep the continuation going; otherwise stop it
      if not (string.find(continuation, ",$")) then
        inv.items.trigger.affectModsContinuation = false
      end -- if

    elseif (inv.items.trigger.keywordsContinuation) then
      -- Add the continuation to the existing keywords
      inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldKeywords,
                            (inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldKeywords) 
                             or "") .. " " .. continuation)

    elseif (inv.items.trigger.nameContinuation) then
      -- Add the continuation to the existing name
      inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldName,
                            (inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldName) 
                             or "") .. " " .. continuation)

    else
      -- Placeholder to add continuation support for other things (notes? others?)
    end -- if
  end -- if

  if (material ~= nil) then
    material = Trim(material)
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldMaterial, material)
    dbot.debug("Material = \"" .. material .. "\"")
  end -- if

  if (foundAt ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldFoundAt, foundAt)
    dbot.debug("Found at = \"" .. foundAt .. "\"")
  end -- if

  if (ownedBy ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldOwnedBy, ownedBy)
    dbot.debug("Found at = \"" .. ownedBy .. "\"")
  end -- if

  if (clan ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldClan, clan)
    dbot.debug("From clan \"" .. clan .. "\"")
  end -- if

  if (spellUses ~= nil) and (spellLevel ~= nil) and (spellName ~= nil) then
    local spellArray = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldSpells) or {}
    spellUses = tonumber(spellUses) or 0

    -- If we already have an entry for this spell, update the count
    local foundSpellMatch = false
    for _, v in ipairs(spellArray) do
      if (v.level == spellLevel) and (v.name == spellName) then
        v.count = v.count + spellUses
        foundSpellMatch = true
        break
      end -- if
    end -- if

    -- If we don't have an entry yet for this spell, add one 
    if (foundSpellMatch == false) then
      table.insert(spellArray, { level=spellLevel, name=spellName, count=spellUses }) 
    end -- if

    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldSpells, spellArray)
  end -- if

  if (leadsTo ~= nil) then
    leadsTo = Trim(leadsTo)
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldLeadsTo, leadsTo)
    dbot.debug("Leads to = \"" .. leadsTo .. "\"")
  end -- if

  -- Container stats
  if (capacity ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldCapacity, dbot.tonumber(capacity))
    dbot.debug("Capacity = \"" .. capacity .. "\"")
  end -- if

  if (holding ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldHolding, dbot.tonumber(holding))
    dbot.debug("Holding = \"" .. holding .. "\"")
  end -- if

  if (heaviestItem ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldHeaviestItem, dbot.tonumber(heaviestItem))
    dbot.debug("Container heaviest item = \"" .. heaviestItem .. "\"")
  end -- if

  if (itemsInside ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldItemsInside, dbot.tonumber(itemsInside))
    dbot.debug("Container items inside = \"" .. itemsInside .. "\"")
  end -- if

  if (totWeight ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldTotWeight, dbot.tonumber(totWeight))
    dbot.debug("Container total weight = \"" .. totWeight .. "\"")
  end -- if

  if (itemBurden ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldItemBurden, dbot.tonumber(itemBurden))
    dbot.debug("Container item burden = \"" .. itemBurden .. "\"")
  end -- if

  if (weightReduction ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWeightReduction,
                           dbot.tonumber(weightReduction))
    dbot.debug("Container weight reduction = \"" .. weightReduction .. "\"")
  end -- if


  if (int ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldInt, dbot.tonumber(int))
    dbot.debug("int = \"" .. int .. "\"")
  end -- if

  if (wis ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWis, dbot.tonumber(wis))
    dbot.debug("wis = \"" .. wis .. "\"")
  end -- if

  if (luck ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldLuck, dbot.tonumber(luck))
    dbot.debug("luck = \"" .. luck .. "\"")
  end -- if

  if (str ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldStr, dbot.tonumber(str))
    dbot.debug("str = \"" .. str .. "\"")
  end -- if

  if (dex ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldDex, dbot.tonumber(dex))
    dbot.debug("dex = \"" .. dex .. "\"")
  end -- if

  if (con ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldCon, dbot.tonumber(con))
    dbot.debug("con = \"" .. con .. "\"")
  end -- if

  if (hp ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldHP, dbot.tonumber(hp))
    dbot.debug("hp = \"" .. hp .. "\"")
  end -- if

  if (mana ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldMana, dbot.tonumber(mana))
    dbot.debug("mana = \"" .. mana .. "\"")
  end -- if

  if (moves ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldMoves, dbot.tonumber(moves))
    dbot.debug("moves = \"" .. moves .. "\"")
  end -- if

  if (hit ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldHit, dbot.tonumber(hit))
    dbot.debug("hit = \"" .. hit .. "\"")
  end -- if

  if (dam ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldDam, dbot.tonumber(dam))
    dbot.debug("dam = \"" .. dam .. "\"")
  end -- if

  if (allphys ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAllPhys, dbot.tonumber(allphys))
    dbot.debug("allphys = \"" .. allphys .. "\"")
  end -- if

  if (allmagic ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAllMagic, dbot.tonumber(allmagic))
    dbot.debug("allmagic = \"" .. allmagic .. "\"")
  end -- if


  if (acid ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAcid, dbot.tonumber(acid))
    dbot.debug("acid = \"" .. acid .. "\"")
  end -- if

  if (cold ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldCold, dbot.tonumber(cold))
    dbot.debug("cold = \"" .. cold .. "\"")
  end -- if

  if (energy ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldEnergy, dbot.tonumber(energy))
    dbot.debug("energy = \"" .. energy .. "\"")
  end -- if

  if (holy ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldHoly, dbot.tonumber(holy))
    dbot.debug("holy = \"" .. holy .. "\"")
  end -- if

  if (electric ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldElectric, dbot.tonumber(electric))
    dbot.debug("electric = \"" .. electric .. "\"")
  end -- if

  if (negative ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldNegative, dbot.tonumber(negative))
    dbot.debug("negative = \"" .. negative .. "\"")
  end -- if

  if (shadow ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldShadow, dbot.tonumber(shadow))
    dbot.debug("shadow = \"" .. shadow .. "\"")
  end -- if

  if (magic ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldMagic, dbot.tonumber(magic))
    dbot.debug("magic = \"" .. magic .. "\"")
  end -- if

  if (air ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAir, dbot.tonumber(air))
    dbot.debug("air = \"" .. air .. "\"")
  end -- if

  if (earth ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldEarth, dbot.tonumber(earth))
    dbot.debug("earth = \"" .. earth .. "\"")
  end -- if

  if (fire ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldFire, dbot.tonumber(fire))
    dbot.debug("fire = \"" .. fire .. "\"")
  end -- if

  if (light ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldLight, dbot.tonumber(light))
    dbot.debug("light = \"" .. light .. "\"")
  end -- if

  if (mental ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldMental, dbot.tonumber(mental))
    dbot.debug("mental = \"" .. mental .. "\"")
  end -- if

  if (sonic ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldSonic, dbot.tonumber(sonic))
    dbot.debug("sonic = \"" .. sonic .. "\"")
  end -- if

  if (water ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWater, dbot.tonumber(water))
    dbot.debug("water = \"" .. water .. "\"")
  end -- if

  if (poison ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldPoison, dbot.tonumber(poison))
    dbot.debug("poison = \"" .. poison .. "\"")
  end -- if

  if (disease ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldDisease, dbot.tonumber(disease))
    dbot.debug("disease = \"" .. disease .. "\"")
  end -- if

  if (slash ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldSlash, dbot.tonumber(slash))
    dbot.debug("slash = \"" .. slash .. "\"")
  end -- if

  if (pierce ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldPierce, dbot.tonumber(pierce))
    dbot.debug("pierce = \"" .. pierce .. "\"")
  end -- if

  if (bash ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldBash, dbot.tonumber(bash))
    dbot.debug("bash = \"" .. bash .. "\"")
  end -- if


  if (avedam ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAveDam, dbot.tonumber(avedam))
    dbot.debug("avedam = \"" .. avedam .. "\"")
  end -- if

  if (tmpAvedam ~= nil) then
    local currentAvedam = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldAveDam) or 0
    local newAvedam = dbot.tonumber(tmpAvedam) + currentAvedam
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldAveDam, newAvedam)
    dbot.debug("tmpAvedam = \"" .. tmpAvedam .. "\"")
  end -- if

  if (tmpHR ~= nil) then
    local currentHR = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldHit) or 0
    local newHR = dbot.tonumber(tmpHR) + currentHR
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldHit, newHR)
    dbot.debug("tmpHR = \"" .. tmpHR .. "\"")
  end -- if

  if (tmpDR ~= nil) then
    local currentDR = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldDam) or 0
    local newDR = dbot.tonumber(tmpDR) + currentDR
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldDam, newDR)
    dbot.debug("tmpDR = \"" .. tmpDR .. "\"")
  end -- if

  if (tmpInt ~= nil) then
    local currentInt = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldInt) or 0
    local newInt = dbot.tonumber(tmpInt) + currentInt
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldInt, newInt)
    dbot.debug("tmpInt = \"" .. tmpInt .. "\"")
  end -- if

  if (tmpWis ~= nil) then
    local currentWis = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldWis) or 0
    local newWis = dbot.tonumber(tmpWis) + currentWis
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWis, newWis)
    dbot.debug("tmpWis = \"" .. tmpWis .. "\"")
  end -- if

  if (tmpLuck ~= nil) then
    local currentLuck = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldLuck) or 0
    local newLuck = dbot.tonumber(tmpLuck) + currentLuck
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldLuck, newLuck)
    dbot.debug("tmpLuck = \"" .. tmpLuck .. "\"")
  end -- if

  if (tmpStr ~= nil) then
    local currentStr = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldStr) or 0
    local newStr = dbot.tonumber(tmpStr) + currentStr
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldStr, newStr)
    dbot.debug("tmpStr = \"" .. tmpStr .. "\"")
  end -- if

  if (tmpDex ~= nil) then
    local currentDex = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldDex) or 0
    local newDex = dbot.tonumber(tmpDex) + currentDex
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldDex, newDex)
    dbot.debug("tmpDex = \"" .. tmpDex .. "\"")
  end -- if

  if (tmpCon ~= nil) then
    local currentCon = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldCon) or 0
    local newCon = dbot.tonumber(tmpCon) + currentCon
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldCon, newCon)
    dbot.debug("tmpCon = \"" .. tmpCon .. "\"")
  end -- if

  if (inflicts ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldInflicts, inflicts)
    dbot.debug("inflicts = \"" .. inflicts .. "\"")
  end -- if

  if (damtype ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldDamType, damtype)
    dbot.debug("damtype = \"" .. damtype .. "\"")
  end -- if

  if (weaponType ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldWeaponType, weaponType)
    dbot.debug("weaponType = \"" .. weaponType .. "\"")
  end -- if

  if (specials ~= nil) then
    inv.items.setStatField(inv.items.identifyPkg.objId, invStatFieldSpecials, specials)
    dbot.debug("specials = \"" .. specials .. "\"")
  end -- if

end -- inv.items.trigger.itemIdStats


function inv.items.trigger.itemIdEnd()

  -- We are at the end of the identification trigger process.  We no longer need the
  -- identification timeout timer and we don't want it going off later.  The deletion
  -- can fail if we are here because the timeout timer called this function.  However,
  -- in that case, the timer will go away anyway because it is a one-shot so we don't
  -- care if the deletion fails.
  dbot.deleteTimer(inv.items.timer.idTimeoutName)

  -- We are done id'ing this item so disable the item's trigger
  EnableTrigger(inv.items.trigger.itemIdStartName,   false)
  EnableTrigger(inv.items.trigger.itemIdStatsName,   false)
  EnableTrigger(inv.items.trigger.suppressWindsName, false)

  -- Because I'm paranoid...
  if (inv.items.identifyPkg == nil) then
    dbot.debug("inv.items.trigger.itemIdEnd: identify package is nil!")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  -- Check if something interferred with the identification.  The "dbot.execute" package
  -- guarantees that the user can't manually try to ID something at the same moment we 
  -- are doing our background identification.  In theory, there shouldn't be any potential
  -- conflict here (i.e., we get back ID results for a different item).  However, it's
  -- probably still helpful to check if the ID we get back matches what we expect.  I'd 
  -- rather find out what is happening the easy way than the hard way...
  -- Note: Auctions and shop items are not ID'ed with their objId (we don't know the objID
  --       until identification completes) so we don't worry about this check for those cases.
  local objId = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldId)
  local objLoc = inv.items.getField(inv.items.identifyPkg.objId, invFieldObjLoc)
  if (objId ~= inv.items.identifyPkg.objId) and (objLoc ~= invItemLocAuction) and 
     (objLoc ~= invItemLocShopkeeper) then
    dbot.debug("Identification wasn't successful for item " .. inv.items.identifyPkg.objId ..
               ": Try again later...")
    inv.items.identifyPkg = nil
    return DRL_RET_BUSY
  end -- if

  -- If we made it through the identification process without discovering we have a
  -- partial identification (e.g., "A full appraisal will reveal further information...")
  -- then we flag it as having passed a full identification.  As a precaution, we verify
  -- that at least one essential stat (name or level) was actually parsed.  If the identify
  -- output was empty, garbled, or timed out without useful data, we leave the item at
  -- "none" so it gets re-identified on the next refresh.
  if (inv.items.getField(inv.items.identifyPkg.objId, invFieldIdentifyLevel) == invIdLevelNone) then
    local hasName  = (inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldName) ~= nil)
    local hasLevel = (inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldLevel) ~= nil)
    if hasName or hasLevel then
      inv.items.setField(inv.items.identifyPkg.objId, invFieldIdentifyLevel, invIdLevelFull)
    else
      dbot.debug("Leaving item " .. inv.items.identifyPkg.objId ..
                 " as unidentified: no stats parsed from identify output")
    end -- if
  end -- if

  local itemType = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldType) or ""
  local itemName = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldName) or ""
  local itemWearable = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldWearable) or "" 
  local affectMods = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldAffectMods) or ""

  -- Add "pseudo-stats" based on item effects (aard terminology is "affect mods") and on
  -- skills specific to particular items or item types.  These make it easier to score
  -- items and item sets.
  if (affectMods ~= "") then
    -- Strip out commas from the list so that we can easily pull mod words out of the string
    local modList = string.gsub(affectMods, ",", ""):lower()
    for mod in modList:gmatch("%S+") do
      inv.items.setStatField(inv.items.identifyPkg.objId, mod, 1)
    end -- for
  end -- if

  -- Add one-off item skills that are not officially affectMods but are very similar
  local weaponType = inv.items.getStatField(inv.items.identifyPkg.objId, invStatFieldWeaponType) or ""
  if (itemName == "Aardwolf Bracers of Iron Grip") then
    inv.items.setStatField(inv.items.identifyPkg.objId, invItemEffectsIronGrip, 1)
  elseif (itemName == "Aardwolf Gloves of Dexterity") then
    inv.items.setStatField(inv.items.identifyPkg.objId, invItemEffectsDualWield, 1)
  elseif string.match(itemWearable, "shield") then
    inv.items.setStatField(inv.items.identifyPkg.objId, invItemEffectsShield, 1)
  elseif (weaponType == "hammer") then
    inv.items.setStatField(inv.items.identifyPkg.objId, invItemEffectsHammerswing, 1)
  end -- if

  -- Persist the just-identified row.  Most callers reach itemIdEnd through
  -- inv.items.identifyCR's loop which saves at line 1340; the exception is
  -- inv.items.timer.idTimeout, which fires itemIdEnd from a one-shot timer
  -- and used to leave the freshly-set identifyLevel and affectMod pseudo-
  -- stats in memory only -- next refresh would silently re-identify the
  -- item.  Saving here covers the timeout path; for the identifyCR path
  -- it is one extra write per item but the row content is unchanged.
  local idObjId = inv.items.identifyPkg.objId
  if (idObjId ~= nil) and (inv.items.table[idObjId] ~= nil) then
    dinv_db.saveItem(idObjId, inv.items.table[idObjId])
  end -- if

  -- The identification process is done!
  inv.items.identifyPkg = nil

end -- inv.items.trigger.itemIdEnd


inv.items.trigger.idItemName = "drlInvItemsTriggerIdItem"
function inv.items.trigger.idItem(line)

  local _, _, id = string.find(line, "Id%s+:%s+(%d+)%s+")
  if (id ~= nil) then
    inv.lastIdentifiedObjectId = id
  end -- if

  if (line == "You do not have that item.") then
    dbot.debug("You do not have the relative item.")
    inv.lastIdentifiedObjectId = 0
  elseif (line == inv.items.identifyFence) then
    EnableTrigger(inv.items.trigger.idItemName, false)
  end -- if

end -- inv.items.trigger.idItem


inv.items.trigger.itemDataStartName = "drlInvItemsTriggerItemDataStart"
inv.items.trigger.itemDataStatsName = "drlInvItemsTriggerItemDataStats"
inv.items.trigger.itemDataEndName   = "drlInvItemsTriggerItemDataEnd"

function inv.items.trigger.itemDataStart(dataType, containerId)
  assert((inv.items.discoverPkg ~= nil), "Discovery start trigger executed when discovery is not in progress")

  -- We are scanning worn items, main inventory items, keyring items, or a container
  if (dataType == "eqdata") then
    inv.items.discoverPkg.loc = invItemLocWorn

  elseif (dataType == "invdata") then
    containerIdNum = tonumber(containerId)
    if (containerIdNum == nil) then
      inv.items.discoverPkg.loc = invItemLocInventory
    else
      inv.items.discoverPkg.loc = containerId
    end -- if

  elseif (dataType == "keyring") then
    inv.items.discoverPkg.loc = invItemLocKeyring

  else
    dbot.debug("inv.items.trigger.itemDataStart: Could not find target item")
    inv.items.trigger.itemDataEnd() -- clean up state
    return DRL_RET_MISSING_ENTRY
  end -- if

  -- Watch for the eqdata, invdata, or keyring end tag so that we can stop scanning
  AddTriggerEx(inv.items.trigger.itemDataEndName,
               "^{/(eqdata|invdata|keyring)}$",
               "inv.items.trigger.itemDataEnd()",
               drlTriggerFlagsBaseline + trigger_flag.OneShot + trigger_flag.OmitFromOutput,
               custom_colour.Custom11, 0, "", "", sendto.script, 0)

  -- Start watching for eqdata or invdata stat lines in the item description
  EnableTrigger(inv.items.trigger.itemDataStatsName, true)

  return DRL_RET_SUCCESS
end -- inv.items.trigger.itemDataStart


function inv.items.trigger.itemDataStats(objId, flags, itemName, level, typeField, unique, wearLoc,
                                         timer, isInvItem)
  local retval = DRL_RET_SUCCESS

  -- Verify the input params exist
  assert(objId     ~= nil, "invitem objectId is nil")
  assert(flags     ~= nil, "invitem flags is nil")
  assert(itemName  ~= nil, "invitem itemName is nil")
  assert(level     ~= nil, "invitem level is nil")
  assert(typeField ~= nil, "invitem typeField is nil")
  assert(unique    ~= nil, "invitem unique is nil")
  assert(wearLoc   ~= nil, "invitem wear location is nil")
  assert(timer     ~= nil, "invitem timer is nil")
  assert((isInvItem == true) or (isInvItem == false), "isInvItem parameter is not a boolean")

  -- Leaflets from the academy auto-disappear the moment they arrive in your inventory.  I've heard
  -- reports that this sometimes confuses dinv although I've never been able to replicate it.  We
  -- can just ignore it entirely here and bypass the issue.
  if (itemName == "an academy fundraising leaflet") then
    dbot.debug("Skipping academy leaflet which will disappear in a moment anyway...")
    return DRL_RET_UNSUPPORTED
  end -- if

  -- Dinv gets confused if an item is identified as an empty/blank item and then later is
  -- changed to a brewed/scribed item.  We don't want to need to re-identify each item as
  -- we brew/scribe it.  As a result, we skip identifying the empty/blank items and only
  -- ID them when they are brewed/scribed and then discovered with a "refresh all".
  if (itemName == "an empty vial") or (itemName == "a blank scroll") then
    return DRL_RET_UNSUPPORTED
  end -- if

  -- Verify the numeric input params are numbers
  objId = tonumber(objId)
  level = tonumber(level)
  typeField = tonumber(typeField)
  unique = tonumber(unique)
  wearLoc = tonumber(wearLoc)
  timer = tonumber(timer)
  if (objId == nil) or (level == nil) or (typeField == nil) or (unique == nil) or 
     (wearLoc == nil) or (timer == nil) then
    dbot.warn("inv.items.trigger.itemDataStats: Detected malformed invitem trigger: " ..
              "numeric parameters are not numbers")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- Get a text name for the item type
  assert((invmon.typeStr ~= nil) and (invmon.typeStr[typeField] ~= nil), 
         "Invalid invdata item type " .. typeField)
  local typeName = invmon.typeStr[typeField]

  -- Get the wear location
  local wearLocText = inv.wearLoc[wearLoc]
  if (wearLocText == nil) or (wearLocText == "") then
    dbot.error("inv.items.trigger.itemDataStats: undefined wear location \"" .. (wearLoc or "nil") .. "\"")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  -- Check if the item is already in the table and get a reference to it if it is
  item = inv.items.getEntry(objId)

  -- If we got here via the invitem trigger and the item already exists, then flag the item as having
  -- possibly changed so that we can re-identify it to see what changed
  if (isInvItem == true) then
    if (item ~= nil) then
      inv.items.mainState = invItemsRefreshDirty -- we want to rescan main inventory now
      retval = inv.items.setField(objId, invFieldIdentifyLevel, invIdLevelNone)
    else
      -- Check if the item is in the frequent item cache.  If it is, there's no need to identify it :)

      local cachedEntry = inv.cache.get(inv.cache.frequent.table, itemName)

      -- Fallback when the in-memory frequent cache misses: look the template up
      -- in the items table by basic name.  This catches the case where dinv has
      -- previously identified an instance of this item type (so its row is in
      -- items) but the in-memory frequent cache doesn't currently know about it
      -- (e.g., the cache was pruned, or the lookup key happens to differ from
      -- what's been added this session).
      local fromSql = false
      if (cachedEntry == nil) then
        cachedEntry = inv.items.lookupTemplateBySql(itemName)
        fromSql = (cachedEntry ~= nil)
      end -- if

      if (cachedEntry ~= nil) then
        cachedEntry.stats.id = objId
        retval = inv.items.setEntry(objId, cachedEntry)
        dbot.note("Identified \"" .. (inv.items.getField(objId, invFieldColorName) or "Unidentified") ..
                  "@W" .. DRL_ANSI_WHITE .. "\" (" .. objId .. ") from " ..
                  (fromSql and "items table" or "frequent cache"))

        -- This item instance probably wasn't in the recent item cache because we don't cache
        -- items that are duplicated in the frequent item cache.  However, it's possible that
        -- the item wasn't in the frequent cache at the time it left our inventory but it is
        -- in the cache now because another instance added it to the frequent cache.  In this
        -- scenario, we want to ensure that we remove the instance from the recent cache to
        -- help keep that cache uncluttered.
        inv.cache.remove(inv.cache.recent.table, objId)

        -- Seed the in-memory frequent cache so the rest of this batch (e.g., the
        -- remaining items in a "dinv consume buy N") skips the SQL round-trip.
        if fromSql then
          inv.cache.add(inv.cache.frequent.table, objId)
        end -- if
      else
        -- True cache miss.  Create a stub; populate the minimum fields that
        -- invitem already gave us (name, level, type) so SQL counts in
        -- inv.consume.displayType and Lua scans in inv.consume.get can at least
        -- find the item before a full identify lands.  Without this the row
        -- holds only colorName and SQL queries WHERE level=N AND name=fullName
        -- silently skip it.
        retval = inv.items.add(objId)
        -- Use a basic name for the colorized name if necessary
        inv.items.setField(objId, invFieldColorName, itemName)
        -- inv.items.add may have restored a fully identified entry from
        -- cache_recent; only seed name/level/type when we got a true stub so we
        -- don't overwrite real data with the truncated invitem version.
        if (inv.items.getField(objId, invFieldIdentifyLevel) == invIdLevelNone) then
          inv.items.setStatField(objId, invStatFieldName, itemName)
          inv.items.setStatField(objId, invStatFieldLevel, level)
          inv.items.setStatField(objId, invStatFieldType, typeName)
        end -- if
      end -- if
    end -- if

  else -- we got here from an eqdata or invdata request
    -- Remember that we saw this item during a discovery/refresh.  This lets us prune items that
    -- are listed in the inventory table but are no longer in our inventory.  This situation could
    -- happen if the user exited(crashed?) after making an inventory change but before saving the change.
    -- It could also happen if the user temporarily disables invmon or if the user makes a change outside
    -- of mushclient (e.g., via telnet).
    inv.items.currentItems[objId] = { discovered = true }

    -- Add the current item to the inventory table if it doesn't exist yet and we are in eqdata or invdata
    -- discovery mode
    if (item == nil) and (inv.items.discoverPkg ~= nil) then
      retval = inv.items.add(objId)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.items.trigger.itemDataStats: Failed to add item " .. objId .. 
                  ": error " .. dbot.retval.getString(retval))
        return retval
      end -- if 
    end -- if

    -- Set the item's location: worn equipment slot, main inventory, keyring, or a container
    -- You may wonder why we always set the location instead of just doing it in the above clause
    -- for when the item is added.  We do this to help recover from the situation where the inventory
    -- table gets out of sync (e.g., user exits before save completes, makes changes outside of
    -- mushclient, accidentally disables invmon, etc.)
    if (inv.items.discoverPkg.loc == invItemLocWorn) then
      retval = inv.items.setField(objId, invFieldObjLoc, wearLocText)
    elseif (inv.items.discoverPkg.loc == invItemLocInventory) then
      retval = inv.items.setField(objId, invFieldObjLoc, invItemLocInventory)
    elseif (inv.items.discoverPkg.loc == invItemLocKeyring) then
      retval = inv.items.setField(objId, invFieldObjLoc, invItemLocKeyring)
    else -- the item is in a container
      retval = inv.items.setField(objId, invFieldObjLoc, tonumber(inv.items.discoverPkg.loc))
    end -- if

    -- Set the colorized name of the item
    retval = inv.items.setField(objId, invFieldColorName, itemName)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.items.trigger.itemDataStats: Failed to set colorName for item " .. objId ..
                ": error " .. dbot.retval.getString(retval))
      return retval
     end -- if

    -- Set the item type from invdata so items show their correct type immediately,
    -- before the full identify command runs. Identify will overwrite with the same value later.
    inv.items.setStatField(objId, invStatFieldType, typeName)
  end -- if

  dbot.debug("inv.items.trigger.itemDataStats: object " .. objId .. ", flags=\"" .. flags .. 
             "\", itemName=\"" .. itemName .. "@W\", level=" .. level .. ", type=" .. typeName .. 
             ", unique=" .. unique .. ", wearLoc=\"" .. wearLocText .. "\", timer=" .. timer)

  -- We're done!
  return retval
end -- inv.items.trigger.itemDataStats


function inv.items.trigger.itemDataEnd()
  -- We are done with the eqdata or invdata output
  EnableTrigger(inv.items.trigger.itemDataStartName, false)
  EnableTrigger(inv.items.trigger.itemDataStatsName, false)

  inv.items.discoverPkg = nil
end -- inv.items.trigger.itemDataEnd


inv.items.trigger.invmonName  = "drlInvItemsTriggerInvmon"
inv.items.trigger.invitemName = "drlInvItemsTriggerInvitem"

function inv.items.trigger.invmon(action, objId, containerId, wearLoc)
  local retval = DRL_RET_SUCCESS

  -- Verify the input params exist
  assert(action ~= nil, "invmon action is nil")
  assert(objId ~= nil, "invmon objectId is nil")
  assert(containerId ~= nil, "invmon containerId is nil")
  assert(wearLoc ~= nil, "invmon wear location is nil")

  -- Verify the input params are numbers
  action = tonumber(action)
  objId = tonumber(objId)
  containerId = tonumber(containerId)
  wearLoc = tonumber(wearLoc)
  if (action == nil) or (objId == nil) or (containerId == nil) or (wearLoc == nil) then
    dbot.debug("Detected malformed invmon trigger: parameters are not numbers")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (inv.items.getEntry(objId) == nil) or
     (containerId ~= -1) and (inv.items.getEntry(containerId) == nil) then
    dbot.debug("Skipping invmon for unknown item and/or container")
    return DRL_RET_MISSING_ENTRY
  end -- if

  if (not inv.config.table.isBuildExecuted) then
    dbot.debug("Skipping invmon, build is not complete yet")
    return DRL_RET_UNINITIALIZED
  end -- if

  -- Get the action
  assert(invmon.action[action] ~= nil, "Undefined invmon action " .. action)

  -- Get the containerId and container basic stats (only valid for invmonActionTakenOutOfContainer
  -- and invmonActionPutIntoContainer)
  local containerText
  local holding, itemsInside, totWeight, weightReduction, itemWeight
  if (containerId == -1) then
    containerText = "none"
  else
    containerText = containerId

    holding = tonumber(inv.items.getStatField(containerId, invStatFieldHolding) or "")
    itemsInside = tonumber(inv.items.getStatField(containerId, invStatFieldItemsInside) or "")
    totWeight = tonumber(inv.items.getStatField(containerId, invStatFieldTotWeight) or "")
    weightReduction = tonumber(inv.items.getStatField(containerId, invStatFieldWeightReduction) or "")
    itemWeight = tonumber(inv.items.getStatField(objId, invStatFieldWeight) or "")
  end -- if

  -- Get the wear location (only valid for invmonActionRemoved or invmonActionWorn)
  local wearLocText = inv.wearLoc[wearLoc]
  if (wearLocText == nil) or (wearLocText == "") then
    dbot.error("inv.items.trigger.invmon: undefined wear location \"" .. (wearLoc or "nil") .. "\"")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  dbot.debug("Invmon trigger: " .. invmon.action[action] .. " object " .. objId .. 
             ", container=" .. containerText .. ", wearLoc=" .. wearLocText)

  -- Add the current item to the inventory table if it doesn't exist yet
  local item = inv.items.getEntry(objId)
  if (item == nil) then
    retval = inv.items.add(objId)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.items.trigger.invmon: Failed to add item " .. objId .. ": error " ..
                dbot.retval.getString(retval))
      return retval
    end -- if 
  end -- if

  -- If the item isn't identified and we aren't already in the middle of a refresh, schedule an
  -- inventory refresh a few seconds from now.  That will give some time to buffer up a few items
  -- if we picked up several things.
  local idLevel = inv.items.getField(objId, invFieldIdentifyLevel)
  local eagerRefreshSec = tonumber(inv.config.table.refreshEagerSec or 0)
  if (idLevel == invIdLevelNone) and (inv.state == invStateIdle) and (eagerRefreshSec > 0) then
    inv.items.refreshAtTime(0, eagerRefreshSec)
  end -- if

  if (action == invmonActionRemoved) then
    if (idLevel == invIdLevelNone) then
      inv.items.mainState = invItemsRefreshDirty -- we want to rescan main inventory now
    end -- if

    retval = inv.items.setField(objId, invFieldObjLoc, invItemLocInventory)

  elseif (action == invmonActionWorn) then
    retval = inv.items.setField(objId, invFieldObjLoc, wearLocText)

  elseif (action == invmonActionRemovedFromInv) then
    -- If the item is a container, this will remove any items in the container too
    retval = inv.items.remove(objId)

  elseif (action == invmonActionAddedToInv) then
    inv.items.mainState = invItemsRefreshDirty -- we want to rescan main inventory now

    retval = inv.items.setField(objId, invFieldObjLoc, invItemLocInventory)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.items.trigger.invmon: Failed to set location for " .. objId .. ": error "
                .. dbot.retval.getString(retval))
      return retval
    end -- if 

  elseif (action == invmonActionTakenOutOfContainer) then
    if (idLevel == invIdLevelNone) then
      -- An unidentified item is now in main inventory so we want to rescan our main inventory
      inv.items.mainState = invItemsRefreshDirty

      -- The container's stats just changed because the item was removed.  We don't know the
      -- item's weight (or anything else) yet so we can't automatically update the container's
      -- stats.  In this case, we mark the container as not being identified so that we will
      -- re-identify it.
      inv.items.setField(containerId, invFieldIdentifyLevel, invIdLevelNone)
    else
      -- Update the container's stats based on this item's removal
      if (holding == nil) or (itemsInside == nil) or (totWeight == nil) or 
         (weightReduction == nil) or (weightReduction == 0) or (itemWeight == nil) then
        -- If we don't have all of the container's stats, force a full re-identification
        inv.items.setField(containerId, invFieldIdentifyLevel, invIdLevelNone)
      else
        holding = holding - (tonumber(inv.items.getStatField(objId, invStatFieldWeight) or "") or 0)
        itemsInside = itemsInside - 1
        totWeight = totWeight - (itemWeight * weightReduction / 100)
      end -- if
    end -- if

    inv.items.setField(objId, invFieldHomeContainer, containerId)
    retval = inv.items.setField(objId, invFieldObjLoc, invItemLocInventory)

  elseif (action == invmonActionPutIntoContainer) then
    -- If we are putting an item into a container before we get a chance to ID it, flag the
    -- container as being dirty so that we rescan it at our next opportunity
    if (idLevel == invIdLevelNone) then
      inv.items.keyword(invItemsRefreshClean, invKeywordOpRemove, "id " .. containerId, true)

      -- The container's stats just changed because the item was added.  We don't know the
      -- item's weight (or anything else) yet so we can't automatically update the container's
      -- stats.  In this case, we mark the container as not being identified so that we will
      -- re-identify it.
      inv.items.setField(containerId, invFieldIdentifyLevel, invIdLevelNone)
    else
      -- Update the container's stats based on this item's addition
      if (holding == nil) or (itemsInside == nil) or (totWeight == nil) or 
         (weightReduction == nil) or (weightReduction == 0) or (itemWeight == nil) then
        -- If we don't have all of the container's stats, force a full re-identification
        inv.items.setField(containerId, invFieldIdentifyLevel, invIdLevelNone)
      else
        holding = holding + (tonumber(inv.items.getStatField(objId, invStatFieldWeight) or "") or 0)
        itemsInside = itemsInside + 1
        totWeight = totWeight + (itemWeight * weightReduction / 100)
      end -- if
    end -- if

    inv.items.setField(objId, invFieldHomeContainer, containerId)
    retval = inv.items.setField(objId, invFieldObjLoc, containerId)

  elseif (action == invmonActionConsumed) then
    retval = inv.items.remove(objId)

  elseif (action == invmonActionPutIntoVault) then
    -- If the item is a container, this will remove any items in the container too
    retval = inv.items.remove(objId) 

  elseif (action == invmonActionRemovedFromVault) then
    inv.items.mainState = invItemsRefreshDirty -- we want to rescan main inventory now

    -- If we removed a container from the vault, we'll recursively add the contents of
    -- the container when we identify the container
    retval = inv.items.setField(objId, invFieldObjLoc, invItemLocInventory)

  elseif (action == invmonActionPutIntoKeyring) then
    -- If we are putting an item into the keyring before we get a chance to ID it, flag the
    -- keyring as being dirty so that we rescan it at our next opportunity
    if (idLevel == invIdLevelNone) then
      inv.items.keyringState = invItemsRefreshDirty
    end -- if

    retval = inv.items.setField(objId, invFieldObjLoc, invItemLocKeyring)

  elseif (action == invmonActionGetFromKeyring) then
    if (idLevel == invIdLevelNone) then
      inv.items.mainState = invItemsRefreshDirty -- we want to rescan main inventory now
    end -- if

    retval = inv.items.setField(objId, invFieldObjLoc, invItemLocInventory)
  end -- if

  -- If we updated a container's stats by adding or removing an item and if the container is not
  -- already in line to be re-identified, update the container's stats now.
  if ((action == invmonActionTakenOutOfContainer) or (action == invmonActionPutIntoContainer)) and
     (inv.items.getField(containerId, invFieldIdentifyLevel) ~= nil) and
     (inv.items.getField(containerId, invFieldIdentifyLevel) ~= invIdLevelNone) then
    inv.items.setStatField(containerId, invStatFieldHolding, (holding or 0))
    inv.items.setStatField(containerId, invStatFieldItemsInside, (itemsInside or 0))
    inv.items.setStatField(containerId, invStatFieldTotWeight, (totWeight or 0))
  end -- if

  -- Persist any in-memory changes from this invmon event to SQLite.  inv.items.remove
  -- already deleted the row for actions that drop the item (3, 7, 9), so getEntry
  -- returns nil there and we skip.  Save brand-new stubs too: an earlier version of
  -- this code skipped them under the assumption an eager refresh would shortly fill
  -- them in, but most players run with refreshEagerSec=0 so the row would never land
  -- on disk -- the item exists in memory only until the next clean restart and then
  -- vanishes.  v3.0085's invitem fallback also populates name/level/type on the stub
  -- so the persisted row is immediately useful to "dinv consume display" and friends.
  local itemEntry = inv.items.getEntry(objId)
  if (itemEntry ~= nil) then
    dinv_db.saveItem(objId, itemEntry)
  end -- if

  -- For container moves (actions 5/6) the container's stats and/or identifyLevel may
  -- have been mutated above.  Persist the container row too so a crash/reload preserves
  -- the updated stats and any re-identification flag we set.
  if (containerId ~= -1) then
    local containerEntry = inv.items.getEntry(containerId)
    if (containerEntry ~= nil) then
      dinv_db.saveItem(containerId, containerEntry)
    end -- if
  end -- if

  return retval

end -- inv.items.trigger.invmon


----------------------------------------------------------------------------------------------------
-- inv.items.timer: Timer functions for the inv.items module
--
-- Functions:
--  inv.items.timer.idTimeout()
--
----------------------------------------------------------------------------------------------------

inv.items.timer = {}

inv.items.timer.refreshName = "drlInvItemsTimerRefresh"
inv.items.timer.refreshMin  = 5 -- by default, run the item refresh timer every 5 minutes, 0 seconds
inv.items.timer.refreshSec  = 0
inv.items.timer.refreshEagerSec = 5 -- If enabled, run a refresh 5 seconds after acquiring a new item

inv.items.timer.idTimeoutName         = "drlInvItemsTimerIdTimeout"
inv.items.timer.idTimeoutThresholdSec = 15  -- timeout the id request if it doesn't complete in this # sec
inv.items.timer.idTimeoutPeriodSec    = 0.1 -- # sec to sleep between polls for an id request to complete

-- If we fail to complete an identification request in the allotted time, a timer will call
-- this function to clean up the pending identification request.
function inv.items.timer.idTimeout()
  dbot.warn("inv.items.timer.idTimeout: Identification timeout timer just triggered!  " ..
            "Item identification did not complete!")

  -- Clean up the identification request
  inv.items.trigger.itemIdEnd()
end -- inv.items.timer.idTimeout



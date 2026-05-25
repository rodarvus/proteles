----------------------------------------------------------------------------------------------------
--
-- Module to manage portals
--
-- dinv portal use portalId
--
-- inv.portal.use(portalQuery)
--
----------------------------------------------------------------------------------------------------

inv.portal = {}

function inv.portal.use(portalQuery)
  if (portalQuery == nil) then
    dbot.warn("inv.portal.use: Missing portal query parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- If the query is simply the object ID of a portal, use it.  Otherwise, search the inventory
  -- table to get an array of portals matching the query.  If there is more than one match, pick
  -- the first one found.
  local portalId = tonumber(portalQuery) or "" 
  if (portalId == nil) or (portalId == "") then
    -- Catch any relative location keys because they are not compatible with inv.items.searchCR() used
    -- below.  By limiting this, we can use searchCR even when we aren't in a co-routine.  Yes, this
    -- is a bit evil, but otherwise we'd need to run the "portal use" mode asynchronously which would
    -- be a nightmare with the mapper and cexits.
    if inv.items.isSearchRelative(portalQuery) then
      dbot.warn("inv.portal.use: relative names and locations are not support by the portal mode")
      return DRL_RET_UNSUPPORTED
    end -- if

    -- Get an array of object IDs that match the portal query string
    local idArray, retval = inv.items.searchCR(portalQuery .. " type portal")
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.portal.use: failed to search inventory table: " .. dbot.retval.getString(retval))
      return retval
    end -- if

    -- Let the user know if no items matched their query
    if (idArray == nil) or (#idArray == 0) then
      dbot.info("No match found for portal query: \"" .. (portalQuery or "nil") .. "\"")
      return DRL_RET_MISSING_ENTRY
    end -- if

    if (#idArray > 1) then
      dbot.warn("Found multiple portals matching query \"" .. (portalQuery or "nil") .. "\"")
    end -- if

    portalId = idArray[1]

  end -- if

  local origId, origLoc
  local portalWish = dbot.wish.has("Portal")

  -- If we have the portal wish, the new portal will go into the "portal" slot.  If we do not
  -- have the portal wish, we will use the "hold" or "second" slot.  This checks if anything is
  -- already at the target location.  If something is there, remember what it is so that we can
  -- put it back when we are done.
  for objId, objInfo in pairs(inv.items.table) do
    local currentLoc = inv.items.getField(objId, invFieldObjLoc) or ""

    -- If we have the portal wish, check if something is already at the portal location.  Similarly,
    -- if we do not have the portal wish, check if something is at the hold or second locations.
    if ((currentLoc == inv.wearLoc[invWearableLocPortal]) and (portalWish == true))  or
       ((currentLoc == inv.wearLoc[invWearableLocHold])   and (portalWish == false)) or
       ((currentLoc == inv.wearLoc[invWearableLocSecond]) and (portalWish == false)) then
      origLoc = currentLoc
      origId = objId
      break
    end -- if
  end -- for

  -- If the new portal is already at the target location, enter it and return success.  Easy peasy.
  if (origId == portalId) then
    return dbot.execute.fast.command("enter")
  end -- if

  -- Queue up several commands to use the portal and then send them to the mud in one burst.  This
  -- is a bit more efficient than sending them one at a time and waiting for the result.
  local commands = {}

  -- If something is at the target location, move it to your main inventory
  if (origId ~= nil) then
    table.insert(commands, "remove " .. origId)
  end -- if

  -- Find the target portal.  If it is in a container, get it out of the container.
  local objLoc = inv.items.getField(portalId, invFieldObjLoc) or ""
  local objLocNum = tonumber(objLoc)
  if (objLoc ~= invItemLocInventory) and (objLocNum ~= nil) then
    table.insert(commands, "get " .. portalId .. " " .. objLocNum)
  end -- if

  -- We have the portal ready.  Hold it and go whoosh.
  table.insert(commands, "hold " .. portalId)
  table.insert(commands, "enter")

  -- Ok, at this point we have the commands to enter the correct portal queued up.  We now want to
  -- set up the commands to put the portal away and swap back to our original equipment.  We do this
  -- after a short 0.5 second delay instead of immediately stacking it with entering the portal.  We
  -- do this because nasty hookers like to sit at portal landing rooms and (definitely-not-illegally)
  -- trigger attacks on hardcore players.  We don't want to be at that landing room any longer than
  -- necessary and we want the mapper to start running us away from that spot asap.  As a result, we
  -- schedule the eq swap shortly afterwords so we don't waste time in the portal landing room.
  local delayedCommands = {}

  -- If we were holding something at the beginning, hold it again now
  if (origId ~= nil) then
    table.insert(delayedCommands, "wear " .. origId .. " " .. origLoc)
  end -- if

  -- Put the portal away if we pulled it out of a container to use it here
  if (objLoc ~= invItemLocInventory) and (objLocNum ~= nil) then
    table.insert(delayedCommands, "put " .. portalId .. " " .. objLoc)
  end -- if

  DoAfterSpecial(0.5, (table.concat(delayedCommands, ";") or ""), sendto.execute)

  return dbot.execute.safe.commands(commands, nil, nil, nil, nil)
end -- inv.portal.use


----------------------------------------------------------------------------------------------------
--
-- Module to manage saveable passes
--
-- Some areas require certain items to be in your main inventory in order to move through the
-- area.  These items, which we will refer to as "passes", are not keys and are saveable.  For
-- example, the area "Giant's Pet Store" requires an employee ID card as part of the process to
-- get a set of keys.  The card is on a mob and we cannot (without botting) automatically kill
-- the mob to get the ID card.
--
-- If a user has aquired a pass and stored it in a container, the "dinv pass" option provides
-- automatic access to the pass whenever desired.  For example, a custom exit could call
-- "dinv pass 12345678 3" to automagically grab the pass item with object ID 12345678 and put
-- it in main inventory and then automagically put the pass item back into its home container
-- after 3 seconds.
--
-- dinv pass [pass id or name] [# seconds]
--
-- inv.pass.use(passNameOrId, useTimeSec)
--
----------------------------------------------------------------------------------------------------

inv.pass = {}

function inv.pass.use(passNameOrId, useTimeSec)
  if (passNameOrId == nil) or (passNameOrId == "") then
    dbot.warn("inv.pass.use: Missing pass name")
    return DRL_RET_INVALID_PARAM
  end -- if

  useTimeSec = tonumber(useTimeSec or "")
  if (useTimeSec == nil) then
    dbot.warn("inv.pass.use: useTimeSec parameter is not a number")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- Find anything that has an objectId or name matching the "passNameOrId" parameter and put it
  -- in main inventory
  local retval = inv.items.get("id " .. passNameOrId .. " || name " .. passNameOrId)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.pass.use: Failed to get pass \"" .. passNameOrId .. "\": " ..
              dbot.retval.getString(retval))
    return retval
  end -- if

  -- Schedule a timer to put the pass away after the specified amount of time.  The inv.items.store()
  -- function puts each specified item into the container that was most recently used to hold the item.
  local storeCommand = "inv.items.store(\"" .. "id " .. passNameOrId .. " || name " .. passNameOrId .. "\")"
  check (DoAfterSpecial(useTimeSec, storeCommand, sendto.script))

  return retval
end -- inv.pass.use



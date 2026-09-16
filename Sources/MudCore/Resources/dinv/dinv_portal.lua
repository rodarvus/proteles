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

-- A hop reserves the coordinator through hold, verified entry and restoration.
-- Duplicate navigation requests are dropped while the owned task is alive.
-- Queue admission and every phase have deadlines; task cleanup releases the lock.
inv.portal.busyUntil = 0
inv.portal.inProgress = false
inv.portal.maxHopSeconds = 15

-- True when the inventory cache shows portalId resting in the slot we enter a
-- portal from (the "portal" slot with the Portal wish, otherwise hold/second).
function inv.portal.isAtTargetSlot(portalId, portalWish)
  local loc = inv.items.getField(portalId, invFieldObjLoc) or ""
  if (portalWish == true) then
    return (loc == inv.wearLoc[invWearableLocPortal])
  end -- if
  return (loc == inv.wearLoc[invWearableLocHold]) or (loc == inv.wearLoc[invWearableLocSecond])
end -- inv.portal.isAtTargetSlot

-- Recheck after the finish request's opening fence, immediately before its
-- commands are sent. Other input may have changed equipment since the hold phase.
-- A failed hold may still restore an empty slot or the original item, but must
-- never enter or overwrite a different item equipped in the meantime.
function inv.portal.beforeFinish(hop)
  if hop.origId and inv.items.getField(hop.origId, invFieldObjLoc) ~= hop.restoreFrom then
    dbot.warn("Portal restoration item moved before entry; check equipment and retry navigation.")
    return DRL_RET_BUSY
  end
  if inv.portal.isAtTargetSlot(hop.id, hop.wish) then return DRL_RET_SUCCESS end
  local changed = hop.enter
  for objId in pairs(inv.items.table) do
    if objId ~= hop.origId and inv.portal.isAtTargetSlot(objId, hop.wish) then changed = true end
  end
  if changed then
    dbot.warn("inv.portal.use: portal slot changed before entry; leaving equipment as it is.")
    return DRL_RET_BUSY
  end
  return DRL_RET_SUCCESS
end -- inv.portal.beforeFinish

-- The hold's suffix fence confirms its invmon updates were processed. Prepare
-- entry and restoration under the hop lock, then recheck the slot at dispatch.
-- ``hop`` retains { id, wish, origId?, origLoc?, putContainer?, enter? }.
function inv.portal.finish(hop)

  -- Build ONE ordered burst: the verified `enter` FIRST, then the swap-back.  They
  -- MUST travel the same channel: dinv sends fence-queue bursts via DINV_BYPASS
  -- (immediate), but `Execute` ("fast.command") is paced -- so an enter sent that
  -- way got overtaken by the bypassed swap-back and fell through to the just-
  -- restored worn portal.  Putting both in one safe.commands burst guarantees the
  -- enter reaches the MUD before the wear/put that restore the worn portal.
  local finish = {}
  hop.enter = inv.portal.isAtTargetSlot(hop.id, hop.wish)
  if hop.enter then
    table.insert(finish, "enter")
  else
    dbot.warn("inv.portal.use: portal " .. tostring(hop.id) ..
              " is not held after the hold; skipping `enter` to avoid falling " ..
              "through to the worn portal.")
  end -- if

  -- Restore the original equipment and stow the portal we pulled out -- AFTER the
  -- enter in the same burst, and BEFORE the lock releases so a churned duplicate
  -- can't slip in mid-swap.
  if (hop.origId ~= nil) then
    hop.restoreFrom = inv.items.getField(hop.origId, invFieldObjLoc)
    if hop.restoreFrom ~= invItemLocInventory then
      if not tonumber(hop.restoreFrom) then return DRL_RET_BUSY end
      table.insert(finish, "get " .. hop.origId .. " " .. hop.restoreFrom)
    end
    table.insert(finish, "wear " .. hop.origId .. " " .. hop.origLoc)
  end -- if
  if (hop.putContainer ~= nil) then
    if not hop.origId and hop.enter then table.insert(finish, "remove " .. hop.id) end
    table.insert(finish, "put " .. hop.id .. " " .. hop.putContainer)
  end -- if

  local retval = dbot.execute.safe.blocking(finish, nil, nil, dbot.callback.default,
    inv.portal.maxHopSeconds, {beforeDispatch = function() return inv.portal.beforeFinish(hop) end})
  if retval ~= DRL_RET_SUCCESS then return retval end
  if hop.origId and inv.items.getField(hop.origId, invFieldObjLoc) ~= hop.origLoc then
    return DRL_RET_MISSING_ENTRY
  end
  local location = inv.items.getField(hop.id, invFieldObjLoc)
  if hop.putContainer and tonumber(location) ~= tonumber(hop.putContainer) then
    return DRL_RET_MISSING_ENTRY
  end
  return DRL_RET_SUCCESS
end -- inv.portal.finish

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

  if inv.portal.inProgress then
    dbot.debug("Portal hop already in progress; ignoring duplicate request.")
    return DRL_RET_SUCCESS
  end
  if not inv.runtime.enabled or not inv.init.initializedActive then return DRL_RET_UNINITIALIZED end
  inv.portal.inProgress = true
  inv.portal.busyUntil = inv.runtime.now() + 30 + inv.portal.maxHopSeconds
  local context = {}
  inv.runtime.start(function()
    return inv.commands.exclusive(function() return inv.portal.useOwned(portalId, context) end,
      nil, inv.portal.maxHopSeconds)
  end, nil, nil, function(retval)
    inv.portal.inProgress, inv.portal.busyUntil = false, 0
    if context.started and retval ~= DRL_RET_SUCCESS then
      dbot.warn("Portal operation interrupted or restoration unconfirmed; check equipment before retrying.")
    end
  end)
  return DRL_RET_SUCCESS
end -- inv.portal.use

function inv.portal.useOwned(portalId, context)
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

  -- Build the entry burst, and remember what the swap-back must restore.  TWO
  -- cases:
  --
  --  * The portal is NOT already believed at the target slot -> swap it in:
  --    displace whatever is there, get the portal from its container (if it lives
  --    in one), and hold it.  ``hop`` records the original equipment + the portal's
  --    container so `finish` can restore them once we've entered.
  --
  --  * The portal IS already believed at the target slot (origId == portalId) ->
  --    no swap, EMPTY burst.  We don't blindly `enter`; the empty burst's fences
  --    cost one round-trip that flushes any in-flight {invmon} so the cache is
  --    authoritative, then `finish` verifies the portal is really there.
  --
  -- Either way the SAME burst+resultFn chain runs (burst -> verified enter +
  -- swap-back -> verification -> release), all under the lock taken above.
  local commands = {}
  local hop = { id = portalId, wish = portalWish }

  if (origId ~= portalId) then
    -- Displace whatever occupies the target slot, and remember it for restore.
    if (origId ~= nil) then
      table.insert(commands, "remove " .. origId)
      hop.origId = origId
      hop.origLoc = origLoc
    end -- if

    -- If the portal lives in a container, get it out first (and stow it after).
    local objLoc = inv.items.getField(portalId, invFieldObjLoc) or ""
    local objLocNum = tonumber(objLoc)
    if (objLoc ~= invItemLocInventory) and (objLocNum ~= nil) then
      table.insert(commands, "get " .. portalId .. " " .. objLocNum)
      hop.putContainer = objLoc
    end -- if

    table.insert(commands, "hold " .. portalId)
  end -- if

  context.started = true
  local retval = dbot.execute.safe.blocking(commands, nil, nil, dbot.callback.default,
    inv.portal.maxHopSeconds)
  if retval ~= DRL_RET_SUCCESS then return retval end
  return inv.portal.finish(hop)
end -- inv.portal.useOwned


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


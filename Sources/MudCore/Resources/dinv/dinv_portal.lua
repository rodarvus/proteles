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

-- A portal hop is a SEQUENTIAL operation, not an async one.  In a MUD commands
-- are sequential; dinv's old design split a hop into time-separated pieces (a
-- fenced get/hold burst, a delayed DoAfterSpecial swap-back, and a gated enter),
-- so a SECOND hop's pieces could interleave with the first's -- and an enter
-- could fire after the first hop's swap-back had restored the (possibly lethal)
-- worn portal.  That is the portal-death bug.  We now run ONE hop to completion
-- -- burst -> verified enter -> swap-back -> release -- before another can start.
-- A use() that arrives while a hop is in flight is dropped (it is redundant
-- mapper churn: the recall is already happening).
--
-- The lock is a deadline timestamp, not a bool, so a broken resultFn chain can
-- never wedge portals forever: it self-expires after ``maxHopSeconds``.  A normal
-- hop releases it early (in the swap-back result).
inv.portal.busyUntil = 0
inv.portal.maxHopSeconds = 15

local function portalNow()
  return tonumber(os.time()) or 0
end -- portalNow

-- True when the inventory cache shows portalId resting in the slot we enter a
-- portal from (the "portal" slot with the Portal wish, otherwise hold/second).
function inv.portal.isAtTargetSlot(portalId, portalWish)
  local loc = inv.items.getField(portalId, invFieldObjLoc) or ""
  if (portalWish == true) then
    return (loc == inv.wearLoc[invWearableLocPortal])
  end -- if
  return (loc == inv.wearLoc[invWearableLocHold]) or (loc == inv.wearLoc[invWearableLocSecond])
end -- inv.portal.isAtTargetSlot

-- resultFn after the entry burst -- the SINGLE gate on `enter`.  The suffix fence
-- has completed, so the server has processed the burst and dinv has applied the
-- resulting {invmon}: the cache is authoritative (and reliable now, because the
-- hop is serialised -- nothing else is touching the portal slot).  Enter ONLY if
-- the portal is genuinely at the target slot, then run the swap-back, still
-- inside the locked window so the next hop waits for it.  ``hop`` carries what the
-- swap-back must restore: { id, wish, origId?, origLoc?, putContainer? }.
function inv.portal.afterHold(hop, retval)
  if (hop == nil) then inv.portal.busyUntil = 0; return end

  -- Build ONE ordered burst: the verified `enter` FIRST, then the swap-back.  They
  -- MUST travel the same channel: dinv sends fence-queue bursts via DINV_BYPASS
  -- (immediate), but `Execute` ("fast.command") is paced -- so an enter sent that
  -- way got overtaken by the bypassed swap-back and fell through to the just-
  -- restored worn portal.  Putting both in one safe.commands burst guarantees the
  -- enter reaches the MUD before the wear/put that restore the worn portal.
  local finish = {}
  if inv.portal.isAtTargetSlot(hop.id, hop.wish) then
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
    table.insert(finish, "wear " .. hop.origId .. " " .. hop.origLoc)
  end -- if
  if (hop.putContainer ~= nil) then
    table.insert(finish, "put " .. hop.id .. " " .. hop.putContainer)
  end -- if

  if (#finish > 0) then
    dbot.execute.safe.commands(finish, nil, nil, inv.portal.afterSwapback, true)
  else
    inv.portal.busyUntil = 0
  end -- if
end -- inv.portal.afterHold

-- resultFn after the swap-back: the hop is complete, release the lock.
function inv.portal.afterSwapback(resultData, retval)
  inv.portal.busyUntil = 0
end -- inv.portal.afterSwapback

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

  -- Serialise: drop a hop that arrives while one is already in flight.  It is
  -- redundant mapper churn (the recall is already happening), and letting it run
  -- is exactly how two hops' swap-backs interleaved into a lethal fall-through.
  -- The lock self-expires (``maxHopSeconds``) so a broken chain can't wedge it.
  if (portalNow() < inv.portal.busyUntil) then
    dbot.debug("inv.portal.use: a portal hop is in flight; dropping duplicate request for " ..
               tostring(portalId))
    return DRL_RET_SUCCESS
  end -- if
  inv.portal.busyUntil = portalNow() + inv.portal.maxHopSeconds

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
  --    container so ``afterHold`` can restore them once we've entered.
  --
  --  * The portal IS already believed at the target slot (origId == portalId) ->
  --    no swap, EMPTY burst.  We don't blindly `enter`; the empty burst's fences
  --    cost one round-trip that flushes any in-flight {invmon} so the cache is
  --    authoritative, then ``afterHold`` verifies the portal is really there.
  --
  -- Either way the SAME burst+resultFn chain runs (burst -> afterHold -> enter +
  -- swap-back -> afterSwapback -> release), all under the lock taken above.
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

  return dbot.execute.safe.commands(commands, nil, nil, inv.portal.afterHold, hop)
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



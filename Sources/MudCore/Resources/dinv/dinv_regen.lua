----------------------------------------------------------------------------------------------------
--
-- Module to manage sleep/wake behaviors such as auto-wearing a regen ring when sleeping
-- Note: Thanks to Moradin for suggesting this mode
--
-- dinv regen [on | off]
--
-- inv.regen.onSleep(sleepLoc)
-- inv.regen.onSleepCR
--
-- inv.regen.onWake
-- inv.regen.onWakeCR
----------------------------------------------------------------------------------------------------

inv.regen = {}

-- Pick the lfinger location by default (yes, we should technically look at the regen item's wearable
-- location and derive it from there...but currently only regen rings are available and we can add
-- that later if necessary).
inv.regen.wearableLoc = "lfinger"


inv.regen.aliasName = "invRegenAlias"
function inv.regen.init()
  AddAlias(inv.regen.aliasName,
           "^(sleep|slee|sle|sl)([ ]+[^ ]+)?[ ]*$",
           "",
           alias_flag.Enabled + alias_flag.RegularExpression,
           "inv.cli.regen.fn2")

  inv.regen.aliasEnable(inv.config.table.isRegenEnabled)
end -- inv.regen.init


function inv.regen.aliasEnable(enable)
  EnableAlias(inv.regen.aliasName, enable)
end -- inv.regen.aliasEnable


inv.regen.pkg = nil
function inv.regen.onSleep(sleepLoc)

  local retval = DRL_RET_SUCCESS

  local sleepCmd = "sleep"
  if (sleepLoc ~= nil) and (sleepLoc ~= "") then
    sleepCmd = sleepCmd .. sleepLoc
  end -- if

  if (inv.config.table.isRegenEnabled) then

    if (inv.regen.pkg ~= nil) then
      dbot.info("Skipping regen sleep request: another request is in progress")
      retval = DRL_RET_BUSY
    else
      inv.regen.pkg = {}
      inv.regen.pkg.sleepCmd = sleepCmd
      wait.make(inv.regen.onSleepCR)
    end -- if

  else
    check (Send(sleepCmd))
  end -- if

  return retval
end -- inv.regen.onSleep


function inv.regen.onSleepCR()

  if (inv.regen.pkg == nil) then
    dbot.error("inv.regen.onSleepCR: regen package is nil!?!")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local sleepCmd = inv.regen.pkg.sleepCmd

  -- Find the user's level.  We don't want to pick a regen item that the user can't wear yet.
  local userLevel = dbot.gmcp.getLevel() or 0
  local searchStr = "affectmods regeneration maxLevel " .. userLevel

  -- First look if the user has at least one item providing the regeneration effect.  Get an ID array
  -- for all regen items (currently just regen rings have this effect.)
  local regenIdArray, retval = inv.items.searchCR(searchStr)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.regen.onSleep: Failed to find wearable items with regeneration effect: " ..
              dbot.retval.getString(retval))
    check (Send(sleepCmd))
    inv.regen.pkg = nil
    return retval
  end -- if

  -- If the user doesn't have a regen ring, we are done.  Go to sleep as normal and return.
  if (#regenIdArray == 0) then
    dbot.info("Skipping regen auto-wear when sleeping: no items with regeneration effect found")
    check (Send(sleepCmd))
    inv.regen.pkg = nil
    return DRL_RET_MISSING_ENTRY
  end -- if

  -- Check worn equipment to see if we are wearing any of the items that provide the regen effect.  If
  -- we are already wearing an item providing regeneration, there's nothing we need to do here.
  for _, objId in ipairs(regenIdArray) do
    if inv.items.isWorn(objId) then
      dbot.debug("Skipping regen auto-wear when sleeping: You are already wearing a regen item")
      check (Send(sleepCmd))
      inv.regen.pkg = nil
      return DRL_RET_SUCCESS
    end -- if
  end -- if

  -- We aren't already wearing a regen item and at least one is available.  Grab the first one in
  -- the array.  It's as good as any other :)
  local regenId = regenIdArray[1]
  local regenName = inv.items.getField(regenId, invFieldColorName) or "Unknown"

  -- Find what item (if any) is at the target location
  local origObjName = "Uninitialized"
  local origObjId
  for objId, _ in pairs(inv.items.table) do
    local objLoc = inv.items.getField(objId, invFieldObjLoc) or ""
    if (objLoc == inv.regen.wearableLoc) then
      origObjId = objId
      origObjName = inv.items.getField(objId, invFieldColorName) or "Unknown"

      -- Remember what item was removed so that we can put it back in inv.regen.onWake()
      inv.config.table.regenOrigObjId = objId
      inv.config.table.regenNewObjId  = regenId
      inv.config.save()
    end -- if
  end -- for
  if (origObjId == nil) then
    dbot.debug("No item is at the target regen location")
  else
    dbot.debug("Replacing \"" .. origObjName .. "@W\" with \"" .. regenName .. "@W\"")
  end -- if

  -- Create a list of commands to remove the old item, get the regen item, and then wear the regen item
  local commandArray = dbot.execute.new()

  -- Remove the old item if it exists (do nothing if there is nothing at that slot)
  if (origObjId ~= nil) then
    retval = inv.items.getItem(origObjId, commandArray)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("Failed to get item \"" .. origObjName .. "@W\": " .. dbot.retval.getString(retval))
      commandArray = dbot.execute.new()
    end -- if
  end -- if

  -- Get and wear the regen item
  retval = inv.items.getItem(regenId, commandArray)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.regen.onSleepCR: Failed to get item \"" .. regenName .. "@W\": " ..
              dbot.retval.getString(retval))
  else
    retval = inv.items.wearItem(regenId, inv.regen.wearableLoc, commandArray)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.regen.onSleepCR: Failed to wear item \"" .. regenName .. "@W\": " ..
                dbot.retval.getString(retval))
    else

      -- Sleep after wearing regen item
      table.insert(commandArray, sleepCmd)

      -- Disable the regen alias while we actually sleep so that we don't recursively sleep/call alias
      inv.regen.aliasEnable(false)

      -- Flush the commands to the mud and wait for confirmation they are complete
      retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.regen.onSleepCR: Failed to auto-wear regen item: " .. dbot.retval.getString(retval))
      end -- if

      inv.regen.aliasEnable(true)

    end -- if
  end -- if

  inv.regen.pkg = nil
  return retval

end -- inv.regen.onSleepCR


function inv.regen.onWake()
  wait.make(inv.regen.onWakeCR)

  return DRL_RET_SUCCESS
end -- inv.regen.onWake


function inv.regen.onWakeCR()

  -- If the regen mode isn't enabled or if there is nothing to swap back, don't do anything here
  if (inv.config.table.isRegenEnabled == false) or (inv.config.table.regenOrigObjId == 0) then
    return DRL_RET_SUCCESS
  end -- if

  -- Spin until either we time out or we detect the dinv is initialized
  local totTime = 0
  local timeout = 5
  local retval = DRL_RET_TIMEOUT
  while (totTime <= timeout) do
    if (inv.init.initializedActive) then
      retval = DRL_RET_SUCCESS
      break
    end -- if
    wait.time(drlSpinnerPeriodDefault)
    totTime = totTime + drlSpinnerPeriodDefault
  end -- while

  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.regen.onWakeCR: timed out waiting for dinv initialization")
    return retval
  end -- if

  -- Spin until GMCP knows that we are out of sleeping mode.  It can take a little time for GMCP
  -- to notice and update its state.
  totTime = 0
  timeout = 5
  local retval = DRL_RET_TIMEOUT
  while (totTime <= timeout) do
    local state = dbot.gmcp.getState()
    if (state == dbot.stateActive) or (state == dbot.stateCombat) then
      retval = DRL_RET_SUCCESS
      break
    end -- if
    wait.time(drlSpinnerPeriodDefault)
    totTime = totTime + drlSpinnerPeriodDefault
  end -- while

  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("inv.regen.onWakeCR: timed out waiting for GMCP to detect that we are awake")
    return retval
  end -- if

  -- If regen mode is enabled and we have a regen ring to swap out, do it!
  if (inv.config.table.isRegenEnabled) and (inv.config.table.regenOrigObjId ~= 0) then

    -- Create a list of commands to store the regen item and get + wear the original item
    local commandArray = dbot.execute.new()
    local regenId = inv.config.table.regenNewObjId
    local origId  = inv.config.table.regenOrigObjId

    -- Store the regen item
    retval = inv.items.storeItem(regenId, commandArray)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.regen.onWakeCR: Failed to store regen item: " .. dbot.retval.getString(retval))
      commandArray = dbot.execute.new()
    end -- if

    -- Get and wear the original item
    retval = inv.items.getItem(origId, commandArray)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.regen.onWakeCR: Failed to get original item: " .. dbot.retval.getString(retval))
    else
      retval = inv.items.wearItem(origId, inv.regen.wearableLoc, commandArray)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.regen.onWakeCR: Failed to wear original item: " .. dbot.retval.getString(retval))
      else
        -- Flush the commands to the mud and wait for confirmation they are complete
        retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 10)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.regen.onWakeCR: Failed to auto-wear item: " .. dbot.retval.getString(retval))
        end -- if
      end -- if
    end -- if
    
  end -- if

  -- We are done with this sleep/wake phase.  Clear out which items to swap.
  inv.config.table.regenOrigObjId = 0
  inv.config.table.regenNewObjId  = 0
  inv.config.save()

  return retval
end -- inv.regen.onWakeCR


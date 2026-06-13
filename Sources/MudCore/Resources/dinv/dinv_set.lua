----------------------------------------------------------------------------------------------------
--
-- Module to manage equipment sets
--
-- dinv set [display | wear | stats] [priority name] <level>
--
-- inv.set.init.atActive()
-- inv.set.fini(doSaveState)
--
-- inv.set.save()
-- inv.set.load()
-- inv.set.reset()
--
-- inv.set.create(priorityName, level, synchronous, intensity)
-- inv.set.createCR()
-- inv.set.createWithHandicap(priorityName, level, handicap)
--
-- inv.set.display(priorityName, level, channel, endTag)
-- inv.set.displayCR()
-- inv.set.displaySet(setName, level, equipSet, channel)
--
-- inv.set.createAndWear(priorityName, level, intensity, endTag)
-- inv.set.createAndWearCR()
-- inv.set.wear(equipSet)
--
-- inv.set.diff(set1, set2, level)
-- inv.set.displayDiff(set1, set2, level, msgString, doPrintHeader)
--
-- inv.set.get(priorityName, level)
-- inv.set.getStats(set, level)
-- inv.set.displayStats(setStats, msgString, doPrintHeader, doDisplayIfZero, channel)
--
-- inv.set.isItemInSet(objId, set)
--
-- inv.set.compare(priorityName, rname, levelSkip, endTag)
-- inv.set.compareCR()
--
-- inv.set.covet(priorityName, auctionNum, levelSkip, endTag)
-- inv.set.covetCR()
--
-- We maintain a table holding the most recently created sets for each priority and level.  This
-- is handy when we want to analyze the usage of a particular item.  It's not a perfect system
-- because we may need to re-run set creation after aquiring new items or getting a good spellup,
-- but it's a decent approximation -- and the user can always re-generate the full table if they
-- have the time and inclination.
--
-- Example format:
--   inv.set.table = { enchanter = {   1 = { hands = { id = someItemId, score = myScore },
--                                           ...
--                                           back =  { id = someItemId, score = myScore } },
--                                   ...
--                                   291 = { hands = { id = someItemId, score = myScore },
--                                           ...
--                                           back =  { id = someItemId, score = myScore } } }
--
--                     psi-melee = {   1 = { abc },
--                                   ...
--                                   291 = { xyz } } }
--
----------------------------------------------------------------------------------------------------

inv.set                  = {}
inv.set.init             = {}
inv.set.table            = {}
inv.set.createPkg        = nil
inv.set.displayPkg       = nil
inv.set.createAndWearPkg = nil

-- We spend more time trying to find optimal sets if we are only looking at one set instead of
-- a full analysis of 200 sets.  The equipment search will be more rigorous at higher intensities.
inv.set.analyzeIntensity = 8
inv.set.createIntensity  = 16


function inv.set.init.atActive()
  -- Sets are lazy-loaded on first access to avoid loading thousands of rows at startup.
  -- Mark as not yet loaded; inv.set.ensureLoaded() will load on first use.
  inv.set.loaded = false
  inv.set.table = {}
  return DRL_RET_SUCCESS
end -- inv.set.init.atActive


-- Ensure the set table is loaded from database. Called before any set access.
function inv.set.ensureLoaded()
  if inv.set.loaded then return end
  inv.set.load()
  inv.set.loaded = true
end


function inv.set.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  if (doSaveState) and inv.set.loaded then
    -- Only save if we actually loaded/modified set data this session
    retval = inv.set.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.set.fini: Failed to save inv.set module data: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- inv.set.fini


function inv.set.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  if not inv.set.table then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM sets")

    for priorityName, levels in pairs(inv.set.table) do
      for level, equipSet in pairs(levels) do
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
            dbot.warn("inv.set.save: Failed to save set " .. priorityName .. "[" .. level .. "]")
            return DRL_RET_INTERNAL_ERROR
          end
        end
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- inv.set.save


function inv.set.load()
  local db = dinv_db.handle
  if not db then
    inv.set.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any set rows exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM sets") do
    count = row.cnt
  end

  if count == 0 then
    inv.set.table = {}
    return DRL_RET_SUCCESS
  end

  inv.set.table = {}
  for row in db:nrows("SELECT priority_name, level, wear_loc, obj_id, score FROM sets") do
    if not inv.set.table[row.priority_name] then
      inv.set.table[row.priority_name] = {}
    end
    if not inv.set.table[row.priority_name][row.level] then
      inv.set.table[row.priority_name][row.level] = {}
    end
    inv.set.table[row.priority_name][row.level][row.wear_loc] = {
      id    = row.obj_id,
      score = row.score,
    }
  end

  return DRL_RET_SUCCESS
end -- inv.set.load


function inv.set.reset()
  inv.set.table = {}

  return inv.set.save()
end -- inv.set.reset


-- Find a set of items in the equipment table that most closely matches the
-- priorities given as a parameter.  Label each of those items in the equipment
-- table with the given name for the set.
--
-- If level is not provided to us, use the character's current level
function inv.set.create(priorityName, level, synchronous, intensity)
  inv.set.ensureLoaded()
  local retval
  local priorityTable

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.set.create: Missing priorityName parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- Attempt to get a valid level.  If the caller doesn't provide a level, use our current level
  level = tonumber(level) or ""
  if (level == nil) or (level == "") then
    level = dbot.gmcp.getLevel()
  end -- if

  -- If the caller doesn't specify if this is a synchronous or asynchronous call, assume it is asynch
  if (synchronous == nil) or (synchronous == "") then
    synchronous = drlAsynchronous
  end -- if

  -- Check if the specified priority exists for the specified level
  priorityTable, retval = inv.priority.get(priorityName, level)
  if (priorityTable == nil) then
    dbot.warn("inv.set.create: Priority \"" .. priorityName .. "\" does not have a priority table " ..
              "for level " .. level)
    return retval
  end -- if

  -- Only allow one set creation at a time
  if (inv.set.createPkg ~= nil) then
    dbot.info("Set creation skipped: another set creation is in progress")
    return DRL_RET_BUSY
  end -- if

  -- Ensure the priority subtable exists.  We deliberately do NOT nil the
  -- existing level entry here: callers can use inv.set.createPkg as the
  -- busy signal instead, which keeps the previous set intact (in both
  -- memory and SQLite) until createCR successfully computes a replacement.
  -- Nilling first plus a wholesale inv.set.save during fini would otherwise
  -- wipe the row permanently if createCR is interrupted (disconnect, error).
  if (inv.set.table[priorityName] == nil) then
    inv.set.table[priorityName] = {}
  end -- if

  -- Everything looks good :)  Kick off the actual creation of the set!
  inv.set.createPkg = {}
  inv.set.createPkg.level = level
  inv.set.createPkg.name = priorityName
  inv.set.createPkg.bonusType = invStatBonusTypeAve -- default to using a weighted average for stats
  inv.set.createPkg.intensity = intensity

  -- We want to call inv.set.createCR() but we may or may not want it in a co-routine.  If the
  -- caller asked us to complete the set creation synchronously, we do not use a co-routine.  Also,
  -- if we are creating a set for the user's current level, we want to use the stat bonus that
  -- they have at this exact moment instead of using the weighted average (which is useful for
  -- guessing bonuses when we don't have the exact data available.)  The only oddity here is that
  -- we also use the weighted average regardless of level when this is a synchronous call.  We need
  -- to sleep/wait to get the exact current stats and we can't do that in synchronous mode.
  if (synchronous == drlSynchronous) then
    inv.set.createCR() -- Call this directly instead of as a co-routine
  elseif (synchronous == drlAsynchronous) then
    if (level == dbot.gmcp.getLevel()) then
      inv.statBonus.timer.update(0, 0.1)
      inv.set.createPkg.bonusType = invStatBonusTypeCurrent
      inv.set.createPkg.waitForStatBonus = true
    end -- if
    wait.make(inv.set.createCR)
  else
    dbot.warn("inv.set.create: Invalid synchronous parameter \"" .. (synchronous or "") .. "\"")
    retval = DRL_INVALID_PARAM
  end -- if

  return retval
end -- inv.set.create


function inv.set.createCR()
  local retval = DRL_RET_SUCCESS

  -- Pull params from our co-routine package
  local priorityName = inv.set.createPkg.name
  local level        = inv.set.createPkg.level
  local intensity    = inv.set.createPkg.intensity or inv.set.createIntensity

  -- If we want to use the exact bonuses that the char has right now instead of using the weighted
  -- average for the level, we need to wait for the statBonus timer to complete.  In practice, we
  -- will only stall when we are creating a set for the user's current level.  We can skip this if
  -- the user is creating sets for analysis of other levels.
  if (inv.set.createPkg.waitForStatBonus == true) then
    -- Give the stat bonus timer a chance to run.  Yes, this is a little awkward and we probably
    -- should use a call-by-reference parameter as a callback mechanism to know when the timer
    -- completes.  This probably isn't as evil as it looks at first glance though.  This is not
    -- time critical because this code only runs if someone wears or displays a single equipment
    -- set and waiting a little while won't kill you.  Also, if the timer doesn't manage to
    -- run (which isn't likely) then the worst case scenario is that we pick up the stat bonuses
    -- from the previous set creation for the user's current level.
    wait.time(1)

    local totTime = 0
    local timeout = 2
    while (inv.statBonus.inProgress == true) do
      if (totTime > timeout) then
        dbot.warn("inv.set.createCR: timed out waiting for stat bonus to be detected")
        retval = DRL_RET_TIMEOUT
        break
      end -- if

      wait.time(drlSpinnerPeriodDefault)
      totTime = totTime + drlSpinnerPeriodDefault
    end -- while
  end -- if

  -- Determine how much each stat can increase due to equipment without hitting that stat's ceiling
  local statDelta = inv.statBonus.get(level, inv.set.createPkg.bonusType)

  -- Start with no stat handicaps.  We handicap stats when a set goes "overstat" so that we gradually
  -- bump up the priority of "lesser" stats in an attempt to increase the set's overall score.  We
  -- adjust an overstat stat by x% each iteration.  That allows us to do up to "intensity" iterations.
  local handicap = { int = 0, wis = 0, luck = 0, str = 0, dex = 0, con = 0 }
  local handicapDelta = (1 / intensity) -- Amount that we increase a stat's handicap each iteration

  -- Keep building new sets with greater stat handicaps until we fully compensate for any
  -- overmax stats
  local bestScore = 0
  local bestSet = nil
  local numIters = 0
  local newSet
  local stats
  local score

  repeat

    newSet, stats, score = inv.set.createWithHandicap(priorityName, level, handicap)

    -- Update the set if we have a better score or if we don't have a valid score yet (we may as well put
    -- something in the set so that we don't fail to create a set)
    if (score > bestScore) or ((score == 0) and (bestScore == 0)) then
      local wearLoc
      local itemStruct

      dbot.debug("Updating set based on handicap on iteration " .. numIters)

      for wearLoc,itemStruct in pairs(newSet) do
        if (bestSet ~= nil) and (bestSet[wearLoc] ~= nil) and (bestSet[wearLoc].id ~= itemStruct.id) then
          dbot.debug("Updating set: " .. wearLoc .. " from " .. bestSet[wearLoc].id .. ", to " ..
                     itemStruct.id)
        end -- if
      end -- for

      bestScore = score
      bestSet = newSet
    end -- if

    -- For every stat that is "overstat", discount that stat by handicapping it in the next iteration
    local handicapExistsThisIter = false -- if we see an overmax stat below, we set this to true
    for k,v in pairs(stats) do
      if (statDelta[k] ~= nil) then
        dbot.debug("delta[" .. k .. "] = " .. statDelta[k] .. ", statValue = " .. v)
      end -- if

      if (statDelta[k] ~= nil) and ((v - statDelta[k]) >= 0) then
        handicap[k] = handicap[k] - handicapDelta
        dbot.debug("Set handicap for \"" .. k .. "\" to " .. handicap[k])
        handicapExistsThisIter = true
      end -- if
    end -- for

    if (handicapExistsThisIter == false) then
      break
    end -- if

    numIters = numIters + 1

    -- Each iteration drops the weighting of a handicapped stat
    if (numIters >= intensity) then
      dbot.debug("Breaking out of inv.set.createCR, looped over handicap " .. numIters .. " times")
      break
    end -- if

    -- Yield periodically so we don't appear to hang the system
    if (numIters % 3 == 0) then
      wait.time(0.1)
    end -- if
  until (score < (bestScore * 0.8)) -- Let things anneal a bit, but cut it off if we are < x% of previous best

  -- Some items can be worn in multiple locations (e.g., a ring could be on "lfinger" or "rfinger" or
  -- a medal could be on "medal1" through "medal4").  We want to always be consistent on where items
  -- go so that we don't unnecessarily swap 2 rings back and forth between fingers each time we wear
  -- a set.  The "normalize" code below sorts items by object ID and puts them in order within the set.
  -- For example, the lfinger item will always have a smaller object ID than the rfinger item.
  for _, wlocArray in pairs(inv.wearables) do

    -- If this is a wearable type with more than one location (e.g., "finger", or "medal") then
    -- we sort the locations for that type.  The one exception is that we don't want to sort
    -- the "wielded" and "second" locations because those have very different meanings.
    if (#wlocArray > 1) and (wlocArray[1] ~= "wielded") then
      local idArray = {}

      for _, wloc in ipairs(wlocArray) do
        if (bestSet ~= nil) and (bestSet[wloc] ~= nil) then
          table.insert(idArray, bestSet[wloc])
        end -- if
      end -- for

      table.sort(idArray, function (v1, v2) return v1.id < v2.id end)

      -- We now know the order that the items should be for this wearable type
      -- Put them back in the set in the proper order
      for i, wloc in ipairs(wlocArray) do
        if (i <= #idArray) then
          bestSet[wloc] = idArray[i]
        end -- if
      end -- for
    end -- if
  end -- for

  -- If our best set is empty (maybe we don't have anything in our inventory) then treat that as a
  -- special case and let the caller know about it
  if (bestSet == nil) then
    dbot.warn("inv.set.createCR: No items in your inventory fit the set.")
    dbot.info("Possibility #1: You have not yet built your inventory table (see \"dinv help build\")")
    dbot.info("Possibility #2: You need to refresh your inventory (see \"dinv help refresh\")")
    dbot.info("Possibility #3: You aren\'t actually carrying anything that would go in the set")
    dbot.info("Possibility #4: You have an awesome spellup that maxes your stats and none of your equipment adds anything your priority can use")
    dbot.info("Possibility #5: There is a bug in dinv, but let\'s not go there...")
  end -- if

  -- Commit the new set to memory and disk.  Persisting per-level here means
  -- one-off "dinv set wear" / "dinv set display" / "dinv weapon use" calls
  -- survive a reload without needing to re-run "dinv analyze" -- the previous
  -- code only saved at fini, which left freshly computed sets vulnerable to
  -- crashes and made the matching items show up as "unused" in dinv unused.
  inv.set.table[priorityName][level] = bestSet
  dinv_db.saveSetLevel(priorityName, level, bestSet)

  dbot.debug("Created " .. priorityName .. "[" .. level .. "] set with score " ..
             string.format("%.2f", bestScore))

  -- We are done!
  inv.set.createPkg = nil
  return DRL_RET_SUCCESS
end -- inv.set.createCR


function inv.set.createWithHandicap(priorityName, level, handicap)
  local objId
  local setScore
  local setStats
  local score
  local offhandScore
  local weaponArray = {}

  -- Start a new set that we'll gradually fill in
  local newSet = {}

  -- If level is nil, use the current level
  if (level == nil) then
    level = dbot.gmcp.getLevel() or 0
  end -- if

  -- We don't want to scan GMCP for each item so we grab the char's alignment here outside
  -- of the for loop
  local isGood    = dbot.gmcp.isGood()
  local isNeutral = dbot.gmcp.isNeutral()
  local isEvil    = dbot.gmcp.isEvil()

  -- Pre-filter via SQL: only items that are identified and at or below target level
  local sqlCandidates = nil
  local db = dinv_db.handle
  if db then
    sqlCandidates = {}
    local query = string.format(
      "SELECT obj_id FROM items WHERE level IS NOT NULL AND level <= %d AND identify_level IN ('partial', 'full')",
      level)
    for row in db:nrows(query) do
      sqlCandidates[row.obj_id] = true
    end
  end

  for objId,_ in pairs(inv.items.table) do
    -- Skip items excluded by SQL pre-filter
    if sqlCandidates and not sqlCandidates[objId] then
      -- Item is overleveled or unidentified; skip
    else
    local objIdentified = inv.items.getField(objId, invFieldIdentifyLevel) or ""
    local objLevel      = tonumber(inv.items.getStatField(objId, invStatFieldLevel) or "")
    local objWearables  = inv.items.getStatField(objId, invStatFieldWearable) or ""
    local objWeight     = tonumber(inv.items.getStatField(objId, invStatFieldWeight) or 0)
    local objType       = inv.items.getStatField(objId, invStatFieldType) or ""
    local objDamType    = inv.items.getStatField(objId, invStatFieldDamType) or ""
    local objWeaponType = inv.items.getStatField(objId, invStatFieldWeaponType) or ""

    -- Strip out commas in the flags to make searching easier
    local objFlags = inv.items.getStatField(objId, invStatFieldFlags) or ""
    objFlags = string.gsub(objFlags, ",", "")

    local isHeroOnly = dbot.isWordInString("heroonly", objFlags)
    local baseLevel = level - dbot.gmcp.getTier() * 10

    -- Consider using the object if it is at least partially identified and is at or below our
    -- current level.  For "heroonly" items, we must also ensure that the user's base level (not
    -- including the tier bonus) is at least 200.
    if ((objIdentified == invIdLevelPartial) or (objIdentified == invIdLevelFull)) and
       (objLevel ~= nil) and (objLevel <= level) and
       ((not isHeroOnly) or (baseLevel >= 200)) then

      for objWearable in objWearables:gmatch("%S+") do

        -- Check the object alignment
        if (dbot.isWordInString("anti-good",    objFlags) and isGood)      or
           (dbot.isWordInString("anti-neutral", objFlags) and isNeutral) or
           (dbot.isWordInString("anti-evil",    objFlags) and isEvil)    then
          dbot.debug("Skipping item: align=" .. (dbot.gmcp.getAlign() or "nil") ..
                     ", flags=\"" .. (objFlags or "nil") .. "\"")

        -- Check if we are ignoring this item (it is flagged as "ignored" or is in a container
        -- that is flagged as "ignored)
        elseif inv.items.isIgnored(objId) then
          dbot.debug("Ignoring item " .. objId .. " for set")

        -- Don't fill the portal slot if the user doesn't have the portal wish
        elseif (objWearable == "portal") and (not dbot.wish.has("Portal")) then
          dbot.debug("Skipping item " .. objId .. " for portal slot because user does not have portal wish")

        -- You can't wear a portal in the hold slot once you have the portal wish
        elseif (objWearable == "hold") and dbot.wish.has("Portal") and (objType == "Portal") then
          dbot.debug("Skipping item " .. objId .. " for hold slot because it is a portal and user has portal wish")

        -- Check if the item is a weapon with a disallowed damage type
        elseif (objDamType ~= nil) and (objDamType ~= "") and
               (not inv.priority.damTypeIsAllowed(objDamType, priorityName, level)) then
          -- Skip the current object because it is a weapon with a damtype we don't want

        -- Check if the weapon type is one that the player can use
        elseif (objWeaponType ~= nil) and (objWeaponType ~= "") and (not dbot.wish.has("Weapons")) and
               (not dbot.ability.isAvailable(objWeaponType, level)) then
          dbot.debug("Skipping " .. objWeaponType .. " (" .. objId .. ") -- weapon skill not available")
          -- Skip the current weapon because the player can't use it

        -- The alignment is acceptable, the item isn't ignored, and it doesn't use a disallowed
        -- damage type.  Whew.  Check the other requirements...
        elseif (objWearable ~= nil) and (objWearable ~= "") and (inv.wearables[objWearable] ~= nil) then
          score, offhandScore = inv.score.item(objId, priorityName, handicap, level)
          local nextBest = { id = objId, score = score }

          -- We keep track of all weapons so that we can evaluate the best combination after we
          -- see everything in our inventory
          if (objWearable == "wield") then
            table.insert(weaponArray,
                         { id = objId, score = score, offhand = offhandScore, weight = objWeight })
          end -- if

          local foundUpdate = false
          for _,w in ipairs(inv.wearables[objWearable]) do
            -- Set a default (low) score if we haven't used this slot yet
            if (newSet[w] == nil) then
              newSet[w] = { id = -1, score = -1 }
            end -- if

            -- If the current item's score is greater than the slot's score, iterate and bump
            if (nextBest.score > newSet[w].score) then
              local tmp = newSet[w]
              newSet[w] = nextBest
              local nextBestName = inv.items.getStatField(nextBest.id, invStatFieldName)
              if (nextBestName ~= nil) then
                dbot.debug("Upgrading \"" .. w .. "\" to \"" .. nextBestName .. "\"")
              end -- if

              nextBest = tmp
              foundUpdate = true
            end -- if
          end -- for

          -- prune slots that don't have any items or slots that are ignored
          for _,w in ipairs(inv.wearables[objWearable]) do
            if (newSet[w].id == -1) or (not inv.priority.locIsAllowed(w, priorityName, level)) then
              newSet[w] = nil
            end -- if
          end -- for

          -- If an item was best-in-slot for one wearable location, don't try to use it in
          -- another wearable location.  For example, this covers the case where an item might
          -- be usable as both a hold item or a portal item.
          if foundUpdate then
            break
          end -- if
        end -- for

      end -- if
    end -- if
    end -- if sqlCandidates skip
  end -- for

  -- Check if the char has access to dual weapons at this level by checking the char's
  -- class and checking if aard gloves are in the set
  local dualWieldAvailable = dbot.ability.isAvailable("dual wield", level)

  -- Check if the set has aard gloves in it.  If so, we automatically have access to dual wield :)
  if (dualWieldAvailable == false) and (newSet["hands"] ~= nil) then
    local handsId = tonumber(newSet["hands"].id or "")
    if (handsId ~= nil) then
      local handsName = inv.items.getStatField(handsId, invStatFieldName) or ""
      if (handsName == "Aardwolf Gloves of Dexterity") then
        dualWieldAvailable = true
      end -- if
    end -- if
  end -- if

  -- Check if the priority explicitly bans the "second" wield slot
  if (dualWieldAvailable) then
    dualWieldAvailable = inv.priority.locIsAllowed(inv.wearLoc[invWearableLocSecond], priorityName, level)
  end -- if

  -- Get subclass for weapon compatibility checks (Soldier: no weight restriction,
  -- Guardian: can dual wield with shield)
  local _, subclass = dbot.gmcp.getClass()
  local subclassLower = string.lower(subclass)
  local isGuardian = (subclassLower == "guardian")

  -- We already know the highest scoring solo weapon (it is in the "wielded" slot).  We now
  -- find the highest scoring combination of compatible weapons ("wielded" + "second") if the
  -- char has access to dual wield.
  local bestWeaponSet = { score = 0, primary = nil, offhand = nil }
  if (dualWieldAvailable) then

    -- Get sorted arrays for all primary weapons and offhand weapons
    local offhandArray = dbot.table.getCopy(weaponArray)
    table.sort(weaponArray, function (entry1, entry2) return entry1.score > entry2.score end)
    table.sort(offhandArray, function (entry1, entry2) return entry1.offhand > entry2.offhand end)

    for _, primary in ipairs(weaponArray) do
      for _, offhand in ipairs(offhandArray) do
        if (primary.id ~= offhand.id) and
           ((primary.weight >= offhand.weight * 2) or (subclassLower == "soldier")) then
          if (primary.score + offhand.offhand > bestWeaponSet.score) then
            bestWeaponSet.score = primary.score + offhand.offhand
            bestWeaponSet.primary = { id = primary.id, score = primary.score }
            bestWeaponSet.offhand = { id = offhand.id, score = offhand.offhand }
          end -- if

          break -- this is the highest possible offhand score for the current primary weapon
        end -- if
      end -- for
    end -- for

  end -- if

  local scorePrimary = 0
  local scoreSecond  = 0
  local scoreShield  = 0
  local scoreHold    = 0

  if (newSet[inv.wearLoc[invWearableLocWielded]] ~= nil) then
    scorePrimary = newSet[inv.wearLoc[invWearableLocWielded]].score or 0
  end -- if
  if (newSet[inv.wearLoc[invWearableLocSecond]] ~= nil) then
    scoreSecond = newSet[inv.wearLoc[invWearableLocSecond]].score or 0
  end -- if
  if (newSet[inv.wearLoc[invWearableLocShield]] ~= nil) then
    scoreShield = newSet[inv.wearLoc[invWearableLocShield]].score or 0
  end -- if
  if (newSet[inv.wearLoc[invWearableLocHold]] ~= nil) then
    scoreHold = newSet[inv.wearLoc[invWearableLocHold]].score or 0
  end -- if

  -- Decide between weapon configurations.  Most classes must choose between dual wield (no
  -- shield or hold) and single weapon + shield + hold.  Guardians can dual wield while wearing
  -- a shield, so they have a third option: dual wield + shield (no hold).
  if dualWieldAvailable then
    local scoreSingleWithExtras = scorePrimary + scoreShield + scoreHold
    local scoreDualOnly         = bestWeaponSet.score
    local scoreDualWithShield   = bestWeaponSet.score + scoreShield

    local bestMode = "single"  -- single weapon + shield + hold

    if isGuardian then
      -- Guardian: compare three options
      if (scoreDualWithShield > scoreSingleWithExtras) and (scoreDualWithShield >= scoreDualOnly) then
        bestMode = "dualShield"
      elseif (scoreDualOnly > scoreSingleWithExtras) then
        bestMode = "dual"
      end -- if
    else
      -- Non-guardian: compare two options
      if (scoreDualOnly > scoreSingleWithExtras) then
        bestMode = "dual"
      end -- if
    end -- if

    if (bestMode == "dual") or (bestMode == "dualShield") then
      if inv.priority.locIsAllowed(inv.wearLoc[invWearableLocWielded], priorityName, level) then
        newSet[inv.wearLoc[invWearableLocWielded]] = bestWeaponSet.primary
        newSet[inv.wearLoc[invWearableLocSecond]]  = bestWeaponSet.offhand
      else
        newSet[inv.wearLoc[invWearableLocWielded]] = nil
        newSet[inv.wearLoc[invWearableLocSecond]]  = bestWeaponSet.primary
      end -- if

      if (bestMode == "dualShield") then
        -- Guardian dual wield + shield: keep shield, clear hold
        newSet[inv.wearLoc[invWearableLocHold]] = nil
      else
        -- Standard dual wield: clear both shield and hold
        newSet[inv.wearLoc[invWearableLocShield]] = nil
        newSet[inv.wearLoc[invWearableLocHold]]   = nil
      end -- if
    else
      -- Single weapon mode: clear second weapon
      newSet[inv.wearLoc[invWearableLocSecond]] = nil
    end -- if
  else
    newSet[inv.wearLoc[invWearableLocSecond]] = nil
  end -- if

  setScore, setStats = inv.score.set(newSet, priorityName, level)

  return newSet, setStats, setScore

end -- inv.set.createWithHandicap


inv.set.displayPkg = nil
function inv.set.display(priorityName, level, channel, endTag)
  inv.set.ensureLoaded()
  local retval
  local priorityTable

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.set.display: missing  priorityName parameter")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  level = tonumber(level) or ""
  if (level == nil) or (level == "") then
    level = dbot.gmcp.getLevel()
  end -- if

  -- Check if the specified priority exists for the specified level
  priorityTable, retval = inv.priority.get(priorityName, level)
  if (priorityTable == nil) then
    dbot.warn("inv.set.display: Priority \"" .. priorityName .. "\" does not have a priority table " ..
            "for level " .. level)
    return inv.tags.stop(invTagsSet, endTag, retval)
  end -- if

  -- Only allow one set creation at a time
  if (inv.set.displayPkg ~= nil) then
    dbot.info("Set display skipped: another set display is in progress")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_BUSY)
  end -- if

  inv.set.displayPkg           = {}
  inv.set.displayPkg.name      = priorityName
  inv.set.displayPkg.level     = level
  inv.set.displayPkg.channel   = channel
  inv.set.displayPkg.intensity = inv.set.createIntensity
  inv.set.displayPkg.endTag    = endTag

  -- Kick off the display co-routine to display the set
  wait.make(inv.set.displayCR)

  return DRL_RET_SUCCESS
end -- inv.set.display


function inv.set.displayCR()
  local retval = DRL_RET_SUCCESS

  local priorityName = inv.set.displayPkg.name or "Unknown"
  local level        = inv.set.displayPkg.level or 0
  local channel      = inv.set.displayPkg.channel
  local intensity    = inv.set.displayPkg.intensity or inv.set.createIntensity
  local endTag       = inv.set.displayPkg.endTag

  -- Create the set that we want to display
  retval = inv.set.create(priorityName, level, drlAsynchronous, intensity)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.set.displayCR: failed to create set " .. priorityName .. "[" .. level .. "]: " ..
            dbot.retval.getString(retval))
    inv.set.displayPkg = nil
    return inv.tags.stop(invTagsSet, endTag, retval)
  end -- if

  -- Spin and wait until createCR finishes (signaled by inv.set.createPkg
  -- becoming nil).  Previously this watched inv.set.table[…][level] == nil
  -- but that was both fragile -- it incorrectly fired when the level had
  -- never been analyzed -- and tied to the just-removed premature nil at
  -- the top of inv.set.create.
  local waitForSetDisplayTimeout = 0
  local waitForSetDisplayThreshold = 10
  while (inv.set.createPkg ~= nil) do
    wait.time(drlSpinnerPeriodDefault)
    waitForSetDisplayTimeout = waitForSetDisplayTimeout + drlSpinnerPeriodDefault
    if (waitForSetDisplayTimeout > waitForSetDisplayThreshold) then
      dbot.error("inv.set.displayCR: Failed to create set " .. priorityName .. "[" .. level .. "] within " ..
                 waitForSetDisplayThreshold .. " seconds")
      inv.set.displayPkg = nil
      return inv.tags.stop(invTagsSet, endTag, DRL_RET_TIMEOUT)
    end -- if
  end -- while

  retval = inv.set.displaySet(priorityName, level, inv.set.table[priorityName][level], channel)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.set.displayCR: Failed to display set: " .. dbot.retval.getString(retval))
  end -- if

  inv.set.displayPkg = nil

  return inv.tags.stop(invTagsSet, endTag, retval)

end -- inv.set.displayCR


function inv.set.displaySet(setName, level, equipSet, channel)
  local retval = DRL_RET_SUCCESS

  if (setName == nil) or (setName == "") then
    dbot.warn("inv.set.displaySet: missing priority name parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  level = tonumber(level or "")
  if (channel == nil) then
    if (level == nil) then
      dbot.print("\n@WEquipment set: \"@C" .. setName .. "@W\"\n")
    else
      dbot.print("\n@WEquipment set:    @GLevel " .. string.format("%3d", level) ..
                 " @C" .. setName .. "@w\n")
    end -- if
  end -- if

  for _,v in pairs(inv.wearLoc) do
    if (equipSet ~= nil) and (v ~= "undefined") and (equipSet[v] ~= nil) then

      local score = equipSet[v].score
      local objId = equipSet[v].id

      -- Highlight items that are currently worn
      local locColor = "@W"
      if inv.items.isWorn(objId) then
        locColor = "@Y"
      end -- if

      local objName = inv.items.getField(objId, invFieldColorName)
      if (objName ~= nil) and (objName  ~= "") and (channel == nil) then
        dbot.print(locColor .. "  " .. string.format("%08s", v) .. "@W(" .. string.format("%4d", score) ..
                   "): @GLevel " ..
                   string.format("%3d", inv.items.getStatField(objId, invStatFieldLevel) or 0) ..
                   "@W \"" .. objName .. "\"")
      end -- if

    end -- if
  end -- for

  local setStats = inv.set.getStats(equipSet, level)
  if (setStats ~= nil) then
    if (channel == nil) then
      dbot.print("")
    end -- if

    inv.set.displayStats(setStats, "", true, true, channel)

  else
    dbot.warn("inv.set.displaySet: Failed to retrieve equipment stats for set \"@C" .. setName .. "@W\"")
    retval = DRL_RET_MISSING_ENTRY
  end -- if

  return retval
end -- inv.set.displaySet


function inv.set.createAndWear(priorityName, level, intensity, endTag)
  inv.set.ensureLoaded()
  local retval = DRL_RET_SUCCESS
  local priorityTable

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.set.createAndWear: missing priorityName parameter")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  level = tonumber(level) or ""
  if (level == nil) or (level == "") then
    level = dbot.gmcp.getLevel()
  end -- if

  -- Check if the specified priority exists for the specified level
  priorityTable, retval = inv.priority.get(priorityName, level)
  if (priorityTable == nil) then
    dbot.warn("inv.set.createAndWear: Priority \"" .. priorityName .. "\" does not have a priority table " ..
              "for level " .. level)
    return inv.tags.stop(invTagsSet, endTag, retval)
  end -- if

  if (inv.set.createAndWearPkg ~= nil) then
    dbot.info("Skipping request to wear set: another request is in progress")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_BUSY)
  end -- if

  inv.set.createAndWearPkg              = {}
  inv.set.createAndWearPkg.priorityName = priorityName
  inv.set.createAndWearPkg.level        = level
  inv.set.createAndWearPkg.intensity    = intensity
  inv.set.createAndWearPkg.endTag       = endTag

  wait.make(inv.set.createAndWearCR)

  return retval
end -- inv.set.createAndWear


function inv.set.createAndWearCR()
  local retval

  if (inv.set.createAndWearPkg == nil) then
    dbot.error("inv.set.createAndWear: package is nil!")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local priorityName = inv.set.createAndWearPkg.priorityName or "Unknown"
  local level        = inv.set.createAndWearPkg.level or 0
  local intensity    = inv.set.createAndWearPkg.intensity or inv.set.createIntensity
  local endTag       = inv.set.createAndWearPkg.endTag

  -- Create the set that we want to wear
  retval = inv.set.create(priorityName, level, drlAsynchronous, intensity)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.set.createAndWearCR: failed to create set " .. priorityName .. "[" .. level .. "]: " ..
              dbot.retval.getString(retval))
    inv.set.createAndWearPkg = nil
    return inv.tags.stop(invTagsSet, endTag, retval)
  end -- if

  -- Spin and wait until createCR finishes (signaled by inv.set.createPkg
  -- becoming nil) -- see displayCR for the same migration.
  local totTime = 0
  local timeout = 10
  while (inv.set.createPkg ~= nil) do
    if (totTime > timeout) then
      dbot.warn("inv.set.createAndWearCR: Failed to create set " .. priorityName ..
                "[" .. level .. "] within " .. timeout .. " seconds")
      inv.set.createAndWearPkg = nil
      return inv.tags.stop(invTagsSet, endTag, DRL_RET_TIMEOUT)
    end -- if

    wait.time(drlSpinnerPeriodDefault)
    totTime = totTime + drlSpinnerPeriodDefault
  end -- while

  -- Attempt to wear the set we just created
  retval = inv.set.wear(inv.set.table[priorityName][level])
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("inv.set.createAndWearCR: Failed to wear set: " .. dbot.retval.getString(retval))
  end -- if

  -- Clean up and return
  inv.set.createAndWearPkg = nil
  return inv.tags.stop(invTagsSet, endTag, retval)

end -- inv.set.createAndWearCR


-- Wear all items from the specified set and put away any items unequipped as
-- part of the process.
-- Note: This must be called from within a co-routine
function inv.set.wear(equipSet)
  local retval = DRL_RET_SUCCESS
  local commandArray = dbot.execute.new()

  if (equipSet == nil) then
    dbot.warn("inv.set.wear: missing set parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  local itemLoc
  local itemInfo

  -- Disable refreshes while we are in the middle of wearing an equipment set
  local didDisableRefresh = false
  if (inv.state == invStateIdle) then
    inv.state = invStatePaused
    didDisableRefresh = true
  elseif (inv.state == invStateRunning) then
    dbot.info("Skipping request to wear an inventory set: you are in the middle of an inventory refresh")
    return DRL_RET_BUSY
  end -- if

  -- Suppress misc. unique messages for item slots and items (e.g., "You proudly pin Academy Graduation
  -- Medal to your chest.")
  EnableTrigger(inv.items.trigger.wearSpecialName, true)

  -- Disable the prompt to make the output look cleaner
  dbot.prompt.hide()

  -- It's possible that an equipment set doesn't specify what to wear at a particular location.
  -- In this case we would like to simply leave that wearable location alone and keep using
  -- the equipment (if any) that is already equipped at that location.  However, some locations
  -- are incompatible with each other and we may be forced to store an item to avoid a conflict.
  -- For example, if a set does not have anything at the "second" location but it does include
  -- a "hold" or "shield" item, then we don't have any choice.  We must store the item that
  -- previously was at the "second" location.  The code below loops through all items to find
  -- all currently equipped items and then stores anything that would be incompatible with the
  -- new set.
  --
  -- Guardians can dual wield while wearing a shield, so the shield/second conflict does not
  -- apply to them.  Soldiers have no weapon weight restriction for dual wield.
  local _, wearSubclass = dbot.gmcp.getClass()
  local wearSubclassLower = string.lower(wearSubclass)
  local wearIsGuardian = (wearSubclassLower == "guardian")
  local wearIsSoldier  = (wearSubclassLower == "soldier")

  -- Pre-compute organize targets so storeItem can route items to the correct containers
  local organizeTargets = inv.items.organize.getTargets()

  for _, v in pairs(inv.wearLoc) do
    itemLoc = v or "none"
    if (equipSet[itemLoc] == nil) then
      for objId, objInfo in pairs(inv.items.table) do
        local currentLoc = inv.items.getField(objId, invFieldObjLoc) or ""
        if (currentLoc == itemLoc) then
          local eqPrimary = equipSet[inv.wearLoc[invWearableLocWielded]]
          local eqSecond  = equipSet[inv.wearLoc[invWearableLocSecond]]
          local eqHold    = equipSet[inv.wearLoc[invWearableLocHold]]
          local eqShield  = equipSet[inv.wearLoc[invWearableLocShield]]

          -- Second weapon conflicts with hold (always) and with shield (unless Guardian)
          local secondConflict =
            ((itemLoc == inv.wearLoc[invWearableLocSecond]) and (eqHold ~= nil)) or
            ((itemLoc == inv.wearLoc[invWearableLocSecond]) and (eqShield ~= nil) and (not wearIsGuardian))

          -- Hold and shield conflict with second weapon (hold always, shield unless Guardian)
          local holdShieldConflict =
            ((itemLoc == inv.wearLoc[invWearableLocHold]) and (eqSecond ~= nil)) or
            ((itemLoc == inv.wearLoc[invWearableLocShield]) and (eqSecond ~= nil) and (not wearIsGuardian))

          -- Offhand weapon too heavy for primary (unless Soldier, who has no weight restriction)
          local weightConflict =
            ((itemLoc == inv.wearLoc[invWearableLocSecond]) and (eqPrimary ~= nil) and
             (not wearIsSoldier) and
             (2 * tonumber(inv.items.getStatField(objId, invStatFieldWeight) or 0) >
              tonumber(inv.items.getStatField(eqPrimary.id, invStatFieldWeight) or 0)))

          if secondConflict or holdShieldConflict or weightConflict then

            dbot.debug("Storing incompatible item at location \"" .. itemLoc .. "\"")

            retval = inv.items.storeItem(objId, commandArray, organizeTargets)
            if (retval ~= DRL_RET_SUCCESS) then
              dbot.debug("inv.set.wear: Failed to store item " .. objId .. ": " ..
                         dbot.retval.getString(retval))
            end -- if
          end -- if
        end -- if
      end -- for
    end -- if
  end -- for

  -- Execute the command to store item types that aren't part of the equipment set
  if (commandArray ~= nil) then
    retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 30)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.note("Skipping request to store unused item types: " .. dbot.retval.getString(retval))
    end -- if
    commandArray = dbot.execute.new()
  end -- if

  -- Create a temporary array that we can sort by item location.  We need to wear hands before
  -- we wear wielded or second so that we can dual wield via aard gloves if they are available.
  -- The most convenient way to do that is to simply sort the wearable location alphabetically.
  local sortedEq = {}
  for itemLoc, itemInfo in pairs(equipSet) do
    table.insert(sortedEq, { itemLoc = itemLoc, itemInfo = itemInfo })
  end -- for
  table.sort(sortedEq, function (v1, v2) return v1.itemLoc < v2.itemLoc end)

  -- For each item in the new set, we get the item's object ID and location and then check
  -- what is at that item's desired location.  If it is already worn at that location, we're
  -- done.  Otherwise, store the item that is currently worn.  It would be convenient if we
  -- could simply wear the new item at this point.  However, some items conflict with other
  -- items (e.g., weapon weights, shields, held items, etc.) and it is easier to simply store
  -- everything first and then wear everything in the new set.  We know that there are no
  -- conflicts with the new set (otherwise it wouldn't be a set!) so we don't have to worry
  -- about interference between items in the middle of swapping equipment.
  for _, entry in ipairs(sortedEq) do
    local itemLoc = entry.itemLoc
    local newObjId = entry.itemInfo.id
    local objId
    local objInfo

    -- Find what currently is worn at this item's location
    for objId, objInfo in pairs(inv.items.table) do
      local currentLoc = inv.items.getField(objId, invFieldObjLoc) or ""
      if (currentLoc == itemLoc) then
        if (objId == newObjId) then
          dbot.debug("Loc \"" .. itemLoc .. "\": Keeping objId=" .. objId)
        else
          dbot.debug("Loc \"" .. itemLoc .. "\": Swapping " .. objId .. " for " .. newObjId)

          retval = inv.items.storeItem(objId, commandArray, organizeTargets)
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.note("Skipping request to store item " .. objId .. ": " ..
                       dbot.retval.getString(retval))
          end -- if
        end -- if

        break -- no need to keep searching for the item we are wearing at the target location
      end -- if

    end -- for
  end -- for

  -- Execute the command to store old items
  if (commandArray ~= nil) then
    retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 30)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.note("Skipping request to store old set: " .. dbot.retval.getString(retval))
    end -- if
    commandArray = dbot.execute.new()
  end -- if

  local numNewWornItems = 0

  -- Get all of the new items to wear and wear them!  Yes, we are doing the exact same for loop
  -- that we did above.  It is a little redundant, but it really simplifies things if we can
  -- separate storing old items and wearing new items.  If we mix those two steps, we can have
  -- conflicts where a new item is conflicting with another item worn in a different location
  -- from the previous set (e.g., weapon weights).
  for _, entry in ipairs(sortedEq) do
    local itemLoc = entry.itemLoc
    local itemInfo = entry.itemInfo
    local currentLoc = inv.items.getField(itemInfo.id, invFieldObjLoc) or ""

    -- Swap out items that are not already in the right location
    if (currentLoc ~= itemLoc) then
      retval = inv.items.wearItem(itemInfo.id, itemLoc, commandArray, true)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.debug("inv.set.wear: Failed to wear item " .. (objId or "nil") .. ": " ..
                   dbot.retval.getString(retval))
      else
        numNewWornItems = numNewWornItems + 1
      end -- if
    end -- if
  end -- for

  -- Execute the command to wear new items
  if (commandArray ~= nil) then
    retval = dbot.execute.safe.blocking(commandArray, nil, nil, dbot.callback.default, 30)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.note("Skipping request to wear set: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  if (retval == DRL_RET_SUCCESS) then
    local suffix = ""
    if (numNewWornItems ~= 1) then
      suffix = "s"
    end -- if
    dbot.info("Wore " .. numNewWornItems .. " new item" .. suffix)
  end -- if

  dbot.prompt.show()

  -- Stop suppressing unique item or item slot wear messages (e.g., pinning a medal, aard gloves
  -- snapping, etc.)
  EnableTrigger(inv.items.trigger.wearSpecialName, false)

  -- Re-enable refreshes if we disabled them to wear an equipment set
  if (didDisableRefresh) then
    inv.state = invStateIdle
  end -- if

  inv.items.save()
  return retval

end -- inv.set.wear


function inv.set.diff(set1, set2, level)
  local diff = {}

  if (set1 == nil) or (set2 == nil) then
    dbot.warn("inv.set.diff: nil set given as parameter")
    return diff, DRL_RET_INVALID_PARAM
  end -- if

  local stats1 = inv.set.getStats(set1, level)
  local stats2 = inv.set.getStats(set2, level)

  if (stats1 == nil) or (stats2 == nil) then
    dbot.warn("inv.set.diff: Failed to get stats for given sets")
    return diff, DRL_RET_MISSING_ENTRY
  end -- if

  for statName, statValue in pairs(stats1) do
    diff[statName] = stats2[statName] - stats1[statName]
  end -- if

  return diff, DRL_RET_SUCCESS
end -- if


-- Returns "didFindAStat", retval.  This is helpful in knowing if there was actually a difference
-- between the two given sets.  The "msgString" is a prefix prepended to each display line.  The
-- "doPrintHeader" boolean indicates if we should print a stat header before displaying the stats.
function inv.set.displayDiff(set1, set2, level, msgString, doPrintHeader)
  if (set1 == nil) or (set2 == nil) then
    dbot.warn("inv.set.displayDiff: nil set given as parameter")
    return false, DRL_RET_INVALID_PARAM
  end -- if

  msgString = msgString or ""

  local diffStats = inv.set.diff(set1, set2, level)

  return inv.set.displayStats(diffStats, msgString, doPrintHeader, false, nil)
end -- inv.set.diffStats


-- Returns a set table in the form described for the inv.set.getStats input parameter
function inv.set.get(priorityName, level)
  inv.set.ensureLoaded()

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.set.get: missing priorityName parameter")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  level = tonumber(level) or dbot.gmcp.getLevel()

  if (inv.set.table[priorityName] == nil) then
    dbot.debug("inv.set.get: priority \"" .. priorityName .. "\" sets do not exist")
    return nil, DRL_RET_MISSING_ENTRY
  end -- if

  return inv.set.table[priorityName][level], DRL_RET_SUCCESS

end -- inv.set.get


-- The "set" parameter is a table of the form:
--   { head = { id = someItemId, score = 123  }, lfinger = { id = anotherItemId, score = 456 }, ...  }
-- where each wearable location is a key in the "set" table and each value in the table is a
-- structure holding the stats for the item.
function inv.set.getStats(set, level)
  local retval = DRL_RET_SUCCESS

  if (set == nil) then
    dbot.warn("inv.set.getStats: Attempted to get set stats for nil set")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  local setStats = { int = 0, wis = 0, luck = 0, str = 0, dex = 0, con = 0,
                     hp = 0, mana = 0, moves = 0,
                     hit = 0, dam = 0,
                     avedam = 0, offhandDam = 0,
                     slash = 0, pierce = 0, bash = 0,
                     acid = 0, cold = 0, energy = 0, holy = 0, electric = 0, negative = 0, shadow = 0,
                     poison = 0, disease = 0, magic = 0, air = 0, earth = 0, fire = 0, light = 0,
                     mental = 0, sonic = 0, water = 0,
                     allphys = 0, allmagic = 0,

                     haste = 0, regeneration = 0, sanctuary = 0, invis = 0, flying = 0,
                     detectgood = 0, detectevil = 0, detecthidden = 0, detectinvis = 0, detectmagic = 0,
                     dualwield = 0, irongrip = 0, shield = 0, hammerswing = 0 -- these last 4 are not official "affect mods"
                   }

  for itemLoc, itemStruct in pairs(set) do
    for statName, statValue in pairs(setStats) do
      local objId = tonumber(itemStruct.id) or 0
      local itemValue = inv.items.getStatField(objId, statName)

      -- Offhand weapons should give stats to offhandDam, not avedam
      if (itemLoc == "second") and (statName == invStatFieldAveDam) then
        statName = "offhandDam"
        statValue = setStats[statName]
      end -- if

      if (itemValue ~= nil) then
        setStats[statName] = statValue + itemValue
      end -- if
    end -- for
  end -- for

  -- If the level is available, use it to cap the stats if they are overmax
  level = tonumber(level or "")
  if (level ~= nil) then
    local statsWithCaps = "int wis luck str dex con"

    for statName in statsWithCaps:gmatch("%S+") do
      if (inv.statBonus.equipBonus[level] ~= nil) and
         (inv.statBonus.equipBonus[level][statName] ~= nil) and
         (tonumber(setStats[statName] or 0) > inv.statBonus.equipBonus[level][statName]) then
          dbot.debug("inv.set.getStats: capping " .. statName .. " from " .. setStats[statName] .. " to " ..
          inv.statBonus.equipBonus[level][statName])
        setStats[statName] = inv.statBonus.equipBonus[level][statName]
      end -- if
    end -- for
  end -- if

  return setStats, retval

end -- inv.set.getStats


function inv.set.displayStats(setStats, msgString, doPrintHeader, doDisplayIfZero, channel)
  local setStr = DRL_XTERM_GREY .. (msgString or "")
  local totResists = 0

  -- Track if at least one stat has something in it.  Unless doDisplayIfZero is true, we will
  -- skip displaying stats that don't affect things.
  local didFindAStat = false

  if (setStats == nil) then
    dbot.warn("inv.set.displayStats: set stats are nil")
    return didFindAStat, DRL_RET_INVALID_PARAM
  end -- if

  -- We weight a specific physical or magic resist relative to an "all" resist.  For example, 3 "slash"
  -- resists are equivalent to 1 "all" phys resist because there are 3 physical resist types.  Similarly,
  -- one specific magical resist is worth 1/17 of one "all" magical resist value because there are 17
  -- magical resistance types.
  local resistNames = {}
  resistNames[1]  = { invStatFieldAllPhys, invStatFieldAllMagic }
  resistNames[3]  = { invStatFieldBash,    invStatFieldPierce,   invStatFieldSlash }
  resistNames[17] = { invStatFieldAcid,    invStatFieldCold,     invStatFieldEnergy,
                      invStatFieldHoly,    invStatFieldElectric, invStatFieldNegative,
                      invStatFieldShadow,  invStatFieldMagic,    invStatFieldAir,
                      invStatFieldEarth,   invStatFieldFire,     invStatFieldLight,
                      invStatFieldMental,  invStatFieldSonic,    invStatFieldWater,
                      invStatFieldDisease, invStatFieldPoison }

  for resistWeight, resistTable in pairs(resistNames) do
    for _, resistName in ipairs(resistTable) do
      totResists = totResists + tonumber(setStats[resistName] or 0) / tonumber(resistWeight)
    end -- for
  end -- for
  setStats.totResists = totResists

  local statSizes = { { avedam = 4 }, { offhandDam = 4 }, { hit = 3 }, { dam = 3 },
                      { str = 3 }, { int = 3 }, { wis = 3 }, { dex = 3 }, { con = 3 }, { luck = 3 },
                      { totResists = 3 }, { hp = 4 }, { mana = 4 }, { moves = 4 } }

  local basicHeader = "@W" .. string.rep(" ", #msgString) ..
                      " Ave  Sec  HR  DR Str Int Wis Dex Con Lck Res HitP Mana Move Effects"

  for i, statTable in ipairs(statSizes) do
    for statName, statDigits in pairs(statTable) do
      if (setStats[statName] ~= nil) and (tonumber(setStats[statName]) ~= 0) then
        didFindAStat = true
      end -- if
      setStr = setStr .. (inv.items.colorizeStat(setStats[statName] or 0, statDigits, false) or "nil") .. " "
    end -- for
  end -- for

  -- Effects (these are known on aard as affectMods)
  local effectList = "haste regeneration sanctuary invis flying dualwield irongrip shield hammerswing " ..
                     "detectgood detectevil detecthidden detectinvis detectmagic"
  local effectStr = ""
  for effect in effectList:gmatch("%S+") do
    local effectVal = tonumber(setStats[effect] or "")
    if (effectVal ~= nil) then
      if (effectVal > 0) then
        effectStr = effectStr .. "@G" .. DRL_ANSI_GREEN .. effect .. "@W" .. DRL_ANSI_WHITE .. " "
      elseif (effectVal < 0) then
        effectStr = effectStr .. "@R" .. DRL_ANSI_RED .. effect .. "@W" .. DRL_ANSI_WHITE .. " "
      end -- if
    end -- if
  end -- for

  setStr = setStr .. effectStr

  local colorIndex = 1
  local colorScheme = { { light = "@x083", dark = "@x002" },
                        { light = "@x039", dark = "@x025" }
                      }

  local reportFormat = { { avedam     = "Ave" },
                         { offhandDam = "Sec" },
                         { dam        = "DR"  },
                         { hit        = "HR"  },
                         { str        = "Str" },
                         { int        = "Int" },
                         { wis        = "Wis" },
                         { dex        = "Dex" },
                         { con        = "Con" },
                         { luck       = "Lck" },
                         { totResists = "Res" },
                         { hp         = "HP"  },
                         { mana       = "MN"  },
                         { moves      = "MV"  } }

  local reportStr = (msgString or "") .. "@WSet: "

  for i, statTable in ipairs(reportFormat) do
    for statName, statHdr in pairs(statTable) do
      local currentColors = colorScheme[colorIndex]
      reportStr = reportStr .. currentColors.dark .. statHdr .. currentColors.light ..
                  math.floor(tonumber(setStats[statName] or "") or 0) .. " "

      if (colorIndex == 1) then
        colorIndex = 2
      else
        colorIndex = 1
      end -- if
    end -- for
  end -- for
  reportStr = reportStr .. effectStr

  if (channel ~= nil) then
    check (Execute(channel .. " " .. reportStr))
  else
    if (doDisplayIfZero == true) or (didFindAStat == true) then
      if (doPrintHeader == true) then
        dbot.print(basicHeader)
      end -- if
      dbot.print(setStr)
    end -- if
  end -- if

  return didFindAStat, DRL_RET_SUCCESS
end -- inv.set.displayStats


function inv.set.isItemInSet(objId, set)
  if (objId == nil) or (set == nil) then
    return false
  end -- if

  -- Run through all wearable locations to see if the object is at that location.  TODO: it would
  -- be a tiny bit faster to check only locations an item could be at.
  for wearLoc, wearInfo in pairs(set) do
    if (wearInfo ~= nil) and (objId == wearInfo.id) then
      return true
    end -- if
  end -- for

  return false
end -- inv.set.isItemInSet


inv.set.comparePkg = nil
function inv.set.compare(priorityName, relativeName, levelSkip, endTag)
  inv.set.ensureLoaded()
  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.set.compare: Missing priorityName parameter")
    return inv.tags.stop(invTagsCompare, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (relativeName == nil) or (relativeName == "") then
    dbot.warn("inv.set.compare: Missing relativeName parameter")
    return inv.tags.stop(invTagsCompare, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.set.table[priorityName] == nil) then
    dbot.warn("inv.set.compare: priority \"" .. priorityName .. "\" does not have analysis results.  " ..
              "You may need to run \"" .. pluginNameCmd .. " analyze create " .. priorityName .. "\".")
    return inv.tags.stop(invTagsCompare, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  if (inv.set.comparePkg ~= nil) then
    dbot.info("Skipping comparison of \"" .. relativeName .. "\" for priority \"" .. priorityName ..
              "\": another comparison is in progress")
    return inv.tags.stop(invTagsCompare, endTag, DRL_RET_BUSY)
  end -- if

  inv.set.comparePkg              = {}
  inv.set.comparePkg.priorityName = priorityName
  inv.set.comparePkg.queryString  = "rname " .. relativeName
  inv.set.comparePkg.levelSkip    = levelSkip
  inv.set.comparePkg.endTag       = endTag

  wait.make(inv.set.compareCR)

  return DRL_RET_SUCCESS
end -- inv.set.compare


function inv.set.compareCR()
  local retval = DRL_RET_SUCCESS
  local idArray = nil
  local startLevel = 1 + 10 * dbot.gmcp.getTier()
  local didDisableRefresh = false
  local endTag = inv.set.comparePkg.endTag

  idArray, retval = inv.items.searchCR(inv.set.comparePkg.queryString)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("inv.set.compareCR: failed to search inventory table: " .. dbot.retval.getString(retval))
    dbot.info("Skipping compare request: could not find the specified item in main inventory")

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    dbot.info("Skipping comparison: No items matched query: \"" .. inv.set.comparePkg.queryString .. "\"")

  -- We have the objId for the target item
  elseif (#idArray == 1) then
    objId = tonumber(idArray[1] or "")

    -- If there are residual sets left over from previous analyses that are too low a level to use, we
    -- whack those sets so that they don't confuse the analysis
    for level = 1, (startLevel - 1) do
      local priorityTable = inv.set.table[inv.set.comparePkg.priorityName]
      if (priorityTable ~= nil) and (priorityTable[level] ~= nil) then
        priorityTable[level] = nil
      end -- if
    end -- for

    -- Save the previous set analysis that includes the target item so that we have something to compare
    local tmpAnalysis = inv.set.table[inv.set.comparePkg.priorityName]
    if (tmpAnalysis == nil) then
      dbot.warn("inv.set.compareCR: Failed to find analysis table for priority \"" ..
                inv.set.comparePkg.priorityName .. "\"")
      inv.set.comparePkg = nil
      return inv.tags.stop(invTagsCompare, endTag, DRL_RET_MISSING_ENTRY)
    end -- if

    -- Disable refresh during the comparison
    if (inv.state == invStateIdle) then
      inv.state = invStatePaused
      didDisableRefresh = true
    elseif (inv.state == invStateRunning) then
      dbot.info("Skipping set comparison: you are in the middle of an inventory refresh")
      inv.set.comparePkg = nil
      return inv.tags.stop(invTagsCompare, endTag, DRL_RET_BUSY)
    end -- if

    -- We have a temporary copy of this that we will restore after we are done comparing the new analysis
    inv.set.table[inv.set.comparePkg.priorityName] = nil

    -- Get the item's level so that we can skip analyzing levels below what the item can be used.
    -- If we don't know the item's level, start analyzing at the user's lowest possible level.
    local itemName = inv.items.getField(objId, invFieldColorName) or "Unknown item name"
    local itemLevel = tonumber(inv.items.getStatField(objId, invStatFieldLevel) or "")
    if (itemLevel == nil) or (itemLevel < startLevel) then
      itemLevel = startLevel
    end -- if

    -- Remove the item
    retval = inv.items.remove(objId)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.set.compareCR: Failed to remove objId " .. (objId or "nil") .. ": " ..
                dbot.retval.getString(retval))
    else
      dbot.print("@WAnalyzing optimal \"@C" .. inv.set.comparePkg.priorityName ..
                 "@W\" equipment sets with and without \"" .. itemName .. "\"\n")

      -- Analyze the priority with the item removed so that we can compare the results with what
      -- we had when the item was included
      local resultData = dbot.callback.new()
      retval = inv.analyze.sets(inv.set.comparePkg.priorityName, itemLevel, inv.set.comparePkg.levelSkip,
                                resultData, inv.set.analyzeIntensity)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.set.compareCR: Failed to analyze sets: " .. dbot.retval.getString(retval))
      else
        -- Wait until the analysis is complete
        retval = dbot.callback.wait(resultData, inv.analyze.timeoutThreshold)
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.set.compareCR: Analysis of comparison set failed: " .. dbot.retval.getString(retval))
        end -- if
      end -- if

      -- Add the item back into our inventory
      retval = inv.items.add(objId)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.set.compareCR: Failed to add objId " .. (objId or "nil") .. ": " ..
                  dbot.retval.getString(retval))
      end -- if

      dbot.print("\n@WPriority \"@C" .. inv.set.comparePkg.priorityName .. "@W\" advantages with \"" ..
                 itemName .. DRL_ANSI_WHITE .. "@W\":\n")

      -- Display the difference between when the item was present and when it was removed
      local doDisplayHeader = true
      local minCharLevel = 1 + (10 * dbot.gmcp.getTier())
      local maxCharLevel = 200 + minCharLevel
      local isPartial = false
      for level = itemLevel, maxCharLevel do
        local s1 = inv.set.table[inv.set.comparePkg.priorityName][level]
        local s2 = tmpAnalysis[level]

        -- If both analyses exist and the compared item is used at this level in the set, then display
        -- the analysis differences at this level
        if (s1 ~= nil) and (s2 == nil) then
          isPartial = true
          dbot.info("Comparison at level " .. level .. " failed due to missing @C" ..
                    inv.set.comparePkg.priorityName .. " @Wanalysis for that level")
        elseif (s1 ~= nil) and (s2 ~= nil) and inv.set.isItemInSet(objId, s2) then
          didFindStat = inv.set.displayDiff(s1, s2, level, string.format("Level %3d: ", level), doDisplayHeader)
          if (didFindStat) then
            doDisplayHeader = false
          end -- if
        end -- if
      end -- for

      if isPartial then
        dbot.warn("Comparison may not be accurate due to a partial analysis for priority @C" ..
                  inv.set.comparePkg.priorityName)
        dbot.warn("You may need to re-run the comparion after executing @Gdinv analyze create " ..
                  inv.set.comparePkg.priorityName)
      end -- if

      if (doDisplayHeader) then
        dbot.print("No set with item \"" .. itemName .. DRL_ANSI_WHITE ..
                   "\" is optimal between levels " .. minCharLevel .. " and " .. maxCharLevel)
      end -- if

    end -- if

    -- Restore the original set analysis that includes the target item
    inv.set.table[inv.set.comparePkg.priorityName] = tmpAnalysis

  -- We shouldn't have more than one item match the relative name query string.  This check is just
  -- paranoia...
  else
    dbot.error("inv.set.compareCR: More than one item matched query string \"" ..
               inv.set.comparePkg.queryString .. "\"")
    retval = DRL_RET_INTERNAL_ERROR
  end -- if

  -- Re-enable refreshes if we disabled them during the comparison
  if (didDisableRefresh) then
    inv.state = invStateIdle
  end -- if

  -- We may have updated and saved the interim state during the comparison.  Ensure that we have
  -- the latest state saved now that the comparison is done and everything is back to where we started.
  inv.items.save()
  inv.set.save()

  inv.set.comparePkg = nil
  return inv.tags.stop(invTagsCompare, endTag, retval)
end -- inv.set.compareCR


inv.set.covetPkg = nil
function inv.set.covet(priorityName, auctionNum, levelSkip, endTag)
  inv.set.ensureLoaded()
  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.set.covet: Missing priorityName parameter")
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (auctionNum == nil) or (type(auctionNum) ~= "number") then
    dbot.warn("inv.set.covet: Auction # parameter is not a number!")
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.set.table[priorityName] == nil) then
    dbot.warn("inv.set.covet: priority \"" .. priorityName .. "\" does not have analysis results.  " ..
              "You may need to run \"" .. pluginNameCmd .. " analyze create " .. priorityName .. "\".")
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  if (inv.set.covetPkg ~= nil) then
    dbot.info("Skipping evaluation of auction #" .. auctionNum .. ": another evaluation is in progress")
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_BUSY)
  end -- if

  inv.set.covetPkg              = {}
  inv.set.covetPkg.priorityName = priorityName
  inv.set.covetPkg.auctionNum   = auctionNum
  inv.set.covetPkg.levelSkip    = levelSkip
  inv.set.covetPkg.endTag       = endTag

  wait.make(inv.set.covetCR)

  return DRL_RET_SUCCESS
end -- inv.set.covet


function inv.set.covetCR()
  local startLevel = 1 + 10 * dbot.gmcp.getTier()
  local endTag = inv.set.covetPkg.endTag

  -- This is either an incredibly evil hack or a clever solution to reuse code -- I haven't decided yet.
  -- Everything in the inventory table is predicated on having an object ID for each item.  We don't
  -- know the item's ID yet when we are pulling info from an auction.  So...if we pretend the auction #
  -- is the objId we can move forward with the identification and analysis.  Real object IDs should be
  -- way outside of the range of numbers used for auctions so we are probably not in danger of a conflict
  -- with an actual item.  Probably.
  local objId = inv.set.covetPkg.auctionNum

  -- If there are residual sets left over from previous analyses that are too low a level to use, we
  -- whack those sets so that they don't confuse the analysis
  for level = 1, (startLevel - 1) do
    local priorityTable = inv.set.table[inv.set.covetPkg.priorityName]
    if (priorityTable ~= nil) and (priorityTable[level] ~= nil) then
      priorityTable[level] = nil
    end -- if
  end -- for

  -- Save the previous set analysis that includes the target item so that we have something to compare
  local tmpAnalysis = inv.set.table[inv.set.covetPkg.priorityName]
  if (tmpAnalysis == nil) then
    dbot.warn("inv.set.covetCR: Failed to find analysis table for priority \"" ..
              inv.set.covetPkg.priorityName .. "\"")
    inv.set.covetPkg = nil
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  -- We don't want an inventory refresh triggering in the middle of this auction item evaluation.
  -- Disable refresh during the comparison
  local origRefreshState = inv.state
  if (inv.state == invStateIdle) then
    inv.state = invStatePaused
  elseif (inv.state == invStateRunning) then
    dbot.info("Skipping auction evaluation: you are in the middle of an inventory refresh")
    inv.set.covetPkg = nil
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_BUSY)
  end -- if

  -- Temporarily create an item placeholder with a fake object ID.  We will fill in this placeholder
  -- with information from an auction later.
  local retval = inv.items.add(objId)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.set.covetCR: Failed to add auction fake objId " .. (objId or "nil") .. ": " ..
              dbot.retval.getString(retval))
    inv.set.covetPkg = nil
    inv.state = origRefreshState
    return inv.tags.stop(invTagsCovet, endTag, retval)
  end -- if

  -- Fake a location for the auction item
  inv.items.setField(objId, invFieldObjLoc, invItemLocAuction)

  -- Treat any auction # less than a threshold as a short-term market bid and anything over the threshold
  -- as a long-term market bid.
  local auctionShortLongThreshold = 1000 -- I think anything below 1000 is guaranteed to be short-term
  local auctionCmd
  if (inv.set.covetPkg.auctionNum < auctionShortLongThreshold) then
    auctionCmd = "bid "
  else
    auctionCmd = "lbid "
  end -- if

  -- Attempt to identify the auction item and wait until we have confirmation that the ID completed
  local resultData = dbot.callback.new()
  retval = inv.items.identifyItem(objId, auctionCmd, resultData)
  if (retval == DRL_RET_SUCCESS) then
    retval = dbot.callback.wait(resultData, inv.items.timer.idTimeoutThresholdSec)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.set.covetCR: Identification timed out for auction # " .. inv.set.covetPkg.auctionNum)
    end -- if
  end -- if

  -- Get the item's level so that we can skip analyzing levels below what the item can be used.
  -- If we don't know the item's level, start analyzing at the user's lowest possible level.
  local itemLevel = tonumber(inv.items.getStatField(objId, invStatFieldLevel) or "") or startLevel
  local itemName = inv.items.getStatField(objId, invStatFieldName)

  -- If the identification failed, give the user as much info as possible on the failure
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.note("inv.set.covetCR: Failed to identify auction item #" .. inv.set.covetPkg.auctionNum ..
              ": " .. dbot.retval.getString(retval))

  -- If the identification worked, we'll know the item's name.  Skip the comparison if the
  -- identification did not fully succeed.  This is probably redundant with the above clause where
  -- we check if (retval ~= DRL_RET_SUCCESS) but maybe there are weird corner cases and it doesn't
  -- hurt to be extra paranoid.
  elseif (itemName == nil) then
    retval = DRL_RET_MISSING_ENTRY
    dbot.note("inv.set.covetCR: Failed to identify auction item #" .. inv.set.covetPkg.auctionNum)

  -- Compare the inventory with and without the auction item
  elseif (retval == DRL_RET_SUCCESS) then

    -- We have a temporary copy of this that we will restore after we are done comparing the new analysis
    inv.set.table[inv.set.covetPkg.priorityName] = nil

    dbot.print("@WAnalyzing optimal \"@C" .. inv.set.covetPkg.priorityName ..
               "@W\" equipment sets with and without @Gauction " .. inv.set.covetPkg.auctionNum .. "@w\n")

    -- Analyze the priority with the item added so that we can compare the results with what
    -- we had when the item was not included
    local resultData = dbot.callback.new()
    retval = inv.analyze.sets(inv.set.covetPkg.priorityName, itemLevel, inv.set.covetPkg.levelSkip,
                              resultData, inv.set.analyzeIntensity)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.set.covetCR: Failed to analyze sets: " .. dbot.retval.getString(retval))
    else
      -- Wait until the analysis is complete
      retval = dbot.callback.wait(resultData, inv.analyze.timeoutThreshold, 1)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.set.covetCR: Analysis of set failed: " .. dbot.retval.getString(retval))
      end -- if
    end -- if

    inv.items.setField(objId, invFieldColorName, "Auction #" .. inv.set.covetPkg.auctionNum)
    inv.items.displayLastType = ""
    inv.items.displayItem(objId, invDisplayVerbosityBasic)

    dbot.print("\n@WPriority \"@C" .. inv.set.covetPkg.priorityName .. "@W\" advantages with " ..
               "@Gauction #" .. inv.set.covetPkg.auctionNum .. "@w:\n")

    -- Display the difference between when the item was present and when it was removed
    local doDisplayHeader = true
    local minCharLevel = 1 + (10 * dbot.gmcp.getTier())
    local maxCharLevel = 200 + minCharLevel
    local isPartial = false
    for level = itemLevel, maxCharLevel do
      local s1 = tmpAnalysis[level]
      local s2 = inv.set.table[inv.set.covetPkg.priorityName][level]

      -- If both analyses exist and the coveted item is used at this level in the set, then display
      -- the analysis differences at this level
      if (s1 == nil) and (s2 ~= nil) then
        isPartial = true
        dbot.info("Covet at level " .. level .. " failed due to missing @C" ..
                  inv.set.covetPkg.priorityName .. " @Wanalysis for that level")
      elseif (s1 ~= nil) and (s2 ~= nil) and inv.set.isItemInSet(objId, s2) then
        didFindStat = inv.set.displayDiff(s1, s2, level, string.format("Level %3d: ", level), doDisplayHeader)
        if (didFindStat) then
          doDisplayHeader = false
        end -- if
      end -- if
    end -- for

    if isPartial then
      dbot.warn("Covet may not be accurate due to a partial analysis for priority @C" ..
                inv.set.covetPkg.priorityName)
      dbot.warn("You may need to re-run the covet after executing @Gdinv analyze create " ..
                inv.set.covetPkg.priorityName)
    end -- if

    if (doDisplayHeader) then
      dbot.print("@WNo set with item \"" .. itemName .. DRL_ANSI_WHITE ..
                 "\" is optimal between levels " .. minCharLevel .. " and " .. maxCharLevel)
    end -- if
  end -- if

  -- Remove the item from the inventory and the recent cache
  local removeRetval = inv.items.remove(objId)
  if (removeRetval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.set.covetCR: Failed to remove auction fake objId " .. (objId or "nil") .. ": " ..
              dbot.retval.getString(removeRetval))
    if (retval == DRL_RET_SUCCESS) then
      retval = removeRetval
    end -- if
  end -- if
  removeRetval = inv.cache.remove(inv.cache.recent.table, objId)
  if (removeRetval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.set.covetCR: Failed to remove auction fake objId " .. (objId or "nil") .. ": " ..
              " from the recent cache: " .. dbot.retval.getString(removeRetval))
    if (retval == DRL_RET_SUCCESS) then
      retval = removeRetval
    end -- if
  end -- if

  -- Restore the original set analysis that predates adding the temporary auction item
  inv.set.table[inv.set.covetPkg.priorityName] = tmpAnalysis

  -- We may have saved the interim state during the comparison.  Ensure that we have the latest
  -- state saved now that the comparison is done and everything is back to where we started.
  inv.items.save()
  inv.set.save()

  -- Re-enable refreshes if we disabled them during the comparison
  inv.state = origRefreshState

  -- Clean up and return
  inv.set.covetPkg = nil
  return inv.tags.stop(invTagsCovet, endTag, retval)
end -- inv.set.covetCR



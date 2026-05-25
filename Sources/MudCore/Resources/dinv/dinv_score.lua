----------------------------------------------------------------------------------------------------
--
-- Module to score items and sets based on a specified priority, level, and handicap
--
-- We "handicap" an item or set when it is overmax on one or more stats.  Handicapping an overmax
-- stat lets us see if we can increase the overall score of a set by prioritizing other stats
-- instead.  In other words, we try to trade off unused overmax stats for another stat that we can
-- actually use.
--
-- The base scoring function is inv.score.extended().  It takes a structure representing either an
-- item or a set and scores that structure based on the given parameters.  The inv.score.item() and
-- inv.score.set() functions convert an itemId or a set into the structure required by the
-- inv.score.extended() function and then they call that function behind the scenes.
--
-- inv.score.item(itemId, priorityName, handicap, level)
-- inv.score.set(set, priorityName, handicap, level)
-- inv.score.extended(itemOrSet, priorityName, handicap, level, isOffhand)
--
-- NOTE: An item score caching table (precomputing scores per priority/level/item) was considered
-- to speed up dinv analyze. Deferred because: (1) scores depend on stat bonuses which change with
-- spellups, requiring complex invalidation logic; (2) SQL pre-filtering in set creation (v3.0038)
-- already reduces the number of items scored; (3) the complexity of cache invalidation outweighs
-- the benefit for typical inventory sizes. Revisit only if analyze performance is a problem.
--
----------------------------------------------------------------------------------------------------

inv.score = {}

-- The handicap and level params are optional.  If level is not given, we use the current level.
-- This returns both a primary score and, for weapons, a score for that weapon in an offhand
-- position.  Non-weapons do not have an offhandScore.
function inv.score.item(itemId, priorityName, handicap, level)
  local retval
  local score = 0
  local offhandScore = 0

  itemId = tonumber(itemId) or ""
  if (itemId == nil) or (itemId == "") then
    dbot.warn("inv.score.item: itemId parameter is not a number")
    return score, offhandScore, DRL_RET_INVALID_PARAM
  end -- if

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.score.item: priorityName parameter is missing")
    return score, offhandScore, DRL_RET_INVALID_PARAM
  end -- if

  -- Find the item's stats entry corresponding to the given itemId
  local itemStats = inv.items.getField(itemId, invFieldStats)
  if (itemStats == nil) then
    dbot.warn("inv.score.item: Object ID " .. itemId .. " does not match an identified item in your inventory")
    return score, offhandScore, DRL_RET_MISSING_ENTRY
  end -- if

  -- Get the basic score for the item
  score, retval = inv.score.extended(itemStats, priorityName, handicap, level, false)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.score.item: Failed to score item " .. itemId .. ": " .. dbot.retval.getString(retval))
    return score, offhandScore, retval
  end -- if

  -- Weapons can have two scores: a primary score, and an offhand score
  local itemType = inv.items.getStatField(itemId, invStatFieldWearable) or ""
  if string.match(itemType, "wield") then
    offhandScore, retval = inv.score.extended(itemStats, priorityName, handicap, level, true)
  end -- if

  return score, offhandScore, retval
end -- inv.score.item


-- Get a score for either an item or a set
function inv.score.extended(itemOrSet, priorityName, handicap, level, isOffhand)
  local score = 0
  local priorityTable
  local retval

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.score.extended: priorityName parameter is missing")
    return score, DRL_RET_INVALID_PARAM
  end -- if

  if (itemOrSet == nil) then
    dbot.warn("inv.score.extended: Missing item or set to be scored")
    return score, DRL_RET_INVALID_PARAM
  end -- if

  -- Determine our level (this accounts for tiers so T1 L10 would have a level of 20)
  -- The caller may tell us the target level, otherwise, we use our current level
  level = tonumber(level)
  if (level == nil) then
    level = dbot.gmcp.getLevel()
  end -- if

  -- Pull out the priority table from the priority block for our level
  priorityTable, retval = inv.priority.get(priorityName, level)
  if (priorityTable == nil) then
    dbot.warn("inv.score.extended: Priority \"" .. priorityName .. "\" does not have a priority table " ..
            "for level " .. level)
    return score, retval
  end -- if

  -- Run through all stats and add up the item's score
  for k,v in pairs(itemOrSet) do
    local statKey = k

    -- Use the "offhandDam" priority instead of "avedam" priority if we are evaluating a weapon
    -- for the offhand location
    if (isOffhand == true) and (k == invStatFieldAveDam) then
      statKey = "offhandDam"
    end -- if

    -- Update the score for any effects in the "affectMods" field (yes, I really think it should be
    -- "effectMods", but I'm keeping the terminology aard uses)
    if (k == invStatFieldAffectMods) and (v ~= nil) and (v ~= "") then
      -- Strip out commas from the list so that we can easily pull mod words out of the string
      local modList = string.gsub(v, ",", ""):lower()
      for mod in modList:gmatch("%S+") do
        dbot.debug("inv.score.extended: mod = \"" .. mod .. "\"")
        local modValue = tonumber(priorityTable[mod] or "")
        if (modValue ~= nil) and (modValue ~= 0) then
          score = score + modValue
        end -- if
      end -- for

    -- Update the score for individual stats
    elseif (priorityTable[statKey] ~= nil) then
      local multiplier
      if (priorityTable[statKey] == 0) then
        multiplier = 0
      else
        multiplier = priorityTable[statKey]
      end -- if

      -- some stats have handicaps that reduce their score
      if (handicap ~= nil) and (handicap[statKey] ~= nil) then
        multiplier = multiplier + handicap[statKey]
      end -- if

      score = score + (multiplier * v)
      dbot.debug("Score: " .. string.format("%.3f", score) .. " after key \"" .. 
                 statKey .. "\" with value \"" .. v .. "\", multiplier=" .. multiplier)

    -- Update the score for consolidated stats
    else
      -- If a field in the item or set's stats matches a field in the priority table, we've already
      -- accounted for that portion of the score (see the if clause above.)  In the else clause
      -- here, we handle situations where stats are consolidated.  For example, a priority may
      -- include the "allmagic" or "allphys" resistances while an item may list individual resists.
      -- In that case, we count each individual resist as being worth 1/(# resists) of a full
      -- magic or physical resist.  For example, 1 bash resist is worth 1/3 of a full physical
      -- resist in our scoring because there are three potential types of physical resistances.
      -- If a user wants more granularity than that, they can call out specific resistances in the
      -- priority table (e.g., use invStatFieldBash instead of "allphys").
      local dtype
      local physResists  = { invStatFieldBash,    invStatFieldPierce,   invStatFieldSlash }
      local magicResists = { invStatFieldAcid,    invStatFieldCold,     invStatFieldEnergy,
                             invStatFieldHoly,    invStatFieldElectric, invStatFieldNegative, 
                             invStatFieldShadow,  invStatFieldMagic,    invStatFieldAir,
                             invStatFieldEarth,   invStatFieldFire,     invStatFieldLight, 
                             invStatFieldMental,  invStatFieldSonic,    invStatFieldWater,
                             invStatFieldDisease, invStatFieldPoison }

      for i,v2 in ipairs(magicResists) do
        dtype = v2:lower()
        if (statKey == dtype) and ((priorityTable[invStatFieldAllMagic] or 0) > 0) then
          score = score + (priorityTable[invStatFieldAllMagic] * v / #magicResists)
          break
        end -- if
      end -- for

      for i,v2 in ipairs(physResists) do
        dtype = v2:lower()
        if (statKey == dtype) and ((priorityTable[invStatFieldAllPhys] or 0) > 0) then
          score = score + (priorityTable[invStatFieldAllPhys] * v / #physResists)
          break
        end -- if
      end -- for
    end -- if
  end -- for

  -- In some situations, we may want to give a score bump if we have maxed a particular stat.
  -- For example, navigators gain an extra bypassed area with maxed int and wis.  In that case, 
  -- it is far more valuable to have maxed int and wis than to be "off-by-one" and be one less
  -- than the max.
  local statList = "int luck wis str dex con"
  for stat in statList:gmatch("%S+") do
    local valueOfMaxStat = tonumber(priorityTable["max" .. stat] or 0)
    if (valueOfMaxStat > 0) and
       (inv.statBonus.equipBonus[level] ~= nil) and (inv.statBonus.equipBonus[level][stat] ~= nil) and
       (tonumber(itemOrSet[stat] or 0) >= inv.statBonus.equipBonus[level][stat]) then        
      dbot.debug("Added " .. valueOfMaxStat .. " to score for maxing stat \"@G" .. stat .. "@W\"")
      score = score + valueOfMaxStat
    end -- if
  end -- for

  -- Round to avoid floating-point noise
  score = tonumber(string.format("%.6f", score))

  dbot.debug("Item \"" .. itemOrSet.name .. "\" has a score of " .. string.format("%.3f", score) ..
             " for priority \"" .. priorityName .. "\"")

  return score, DRL_RET_SUCCESS

end -- inv.score.extended


-- The "set" parameter is a table with wearable locations as the keys and objID as the value.
-- Note that we don't have a "handicap" parameter here.  We don't handicap sets.  We handicap
-- the scoring of items as we generate sets.
function inv.score.set(set, priorityName, level)
  local retval
  local setStats
  local setScore

  if (set == nil) then
    dbot.warn("inv.score.set: \"set\" parameter is missing")
    return nil, nil, DRL_RET_INVALID_PARAM
  end -- if

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.score.set: priorityName is missing")
    return nil, nil, DRL_RET_INVALID_PARAM
  end -- if

  setStats = inv.set.getStats(set, level)
  setStats.name = "Set for level " .. (level or "Unknown") .. " " .. priorityName
  setScore, _, retval = inv.score.extended(setStats, priorityName, nil, level, false)

  dbot.debug("setScore = " .. setScore)

  return setScore, setStats, retval
end -- inv.score.set



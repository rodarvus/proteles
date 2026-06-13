----------------------------------------------------------------------------------------------------
--
-- Module to manage analysis of equipment sets
--
-- dinv analyze [list | create | delete | display] <priorityName> <wearable location>
--
-- inv.analyze.sets(priorityName, minLevel, skipLevel, resultData, intensity)
-- inv.analyze.setsCR()
-- inv.analyze.delete(priorityName)
-- inv.analyze.list()
-- inv.analyze.display(priorityName, wearableLoc, endTag)
--
----------------------------------------------------------------------------------------------------

inv.analyze                  = {}
inv.analyze.setsPkg          = nil
inv.analyze.timeoutThreshold = 60


function inv.analyze.sets(priorityName, minLevel, skipLevel, resultData, intensity)
  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.analyze.sets: missing priorityName parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  minLevel = tonumber(minLevel or "")
  if (minLevel == nil) then
    dbot.warn("inv.analyze.sets: invalid non-numeric minLevel parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- Ensure we don't have multiple analyses in progress
  if (inv.analyze.setsPkg ~= nil) then
    dbot.info("Skipping analysis of sets: another analysis is in progress")
    return DRL_RET_BUSY
  end -- if

  inv.analyze.setsPkg               = {}
  inv.analyze.setsPkg.priorityName  = priorityName
  inv.analyze.setsPkg.minLevel      = minLevel
  inv.analyze.setsPkg.skipLevel     = skipLevel
  inv.analyze.setsPkg.intensity     = intensity
  inv.analyze.setsPkg.resultData    = resultData

  wait.make(inv.analyze.setsCR)

  return DRL_RET_SUCCESS
end -- inv.analyze.sets


drlSynchronous  = "synchronous"
drlAsynchronous = "asynchronous"
function inv.analyze.setsCR()
  local currentLevel
  local didDisableRefresh = false
  local retval = DRL_RET_SUCCESS
  local maxLevel = 201 + 10 * dbot.gmcp.getTier()
  local totalLevels

  if (inv.state == invStateRunning) then
    dbot.info("Skipping set analysis: you are in the middle of an inventory refresh")
    retval = DRL_RET_BUSY
  else
    totalLevels = maxLevel - inv.analyze.setsPkg.minLevel
    if (totalLevels == 0) then
      totalLevels = 1 -- we don't want to divide by zero in our analysis
    elseif (totalLevels < 0) then
      dbot.info("Skipping set analysis: minLevel " .. inv.analyze.setsPkg.minLevel ..
                " exceeds your current maxLevel " .. maxLevel)
      retval = DRL_RET_SUCCESS
    end -- if
  end -- if

  -- If we hit a problem either with the current state or with the level range, abort the request
  -- and let the caller know what happened by updating the callback parameter.
  if (retval ~= DRL_RET_SUCCESS) then
    -- Save callback data before clearing the package
    local resultData = inv.analyze.setsPkg.resultData
    inv.analyze.setsPkg = nil

    -- If the user gave us a callback, use it to let the caller know we are done because we failed in some way
    if (resultData ~= nil) then
      dbot.callback.default(resultData, retval)
    end -- if

    return retval
  end -- if

  if (inv.state == invStateIdle) then
    inv.state = invStatePaused
    didDisableRefresh = true
  end -- if

  if (inv.set.table[inv.analyze.setsPkg.priorityName] == nil) then
    inv.set.table[inv.analyze.setsPkg.priorityName] = {}
  end -- if

  dbot.prompt.hide()

  for currentLevel = inv.analyze.setsPkg.minLevel, maxLevel, inv.analyze.setsPkg.skipLevel do
    dbot.debug("Creating @clevel " .. currentLevel .. " @Wanalysis set for @C" .. inv.analyze.setsPkg.priorityName)

    -- inv.set.create no longer nils the entry first (it relied on that as a
    -- busy signal and an interrupted analyze run would permanently wipe rows
    -- via fini's wholesale save).  createCR replaces the entry in-place when
    -- it completes, and the inv.set.createPkg busy-signal below covers the
    -- ready/not-ready check.
    retval = inv.set.create(inv.analyze.setsPkg.priorityName, currentLevel,
                            drlSynchronous, inv.analyze.setsPkg.intensity)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.analyze.setsCR: Failed to create \"" .. (inv.analyze.setsPkg.priorityName or "nil") ..
                "\" set at level " .. currentLevel .. ": " .. dbot.retval.getString(retval))
      break
    end -- if

    -- Show progress and let something else run occasionally
    local levelsChecked = currentLevel - inv.analyze.setsPkg.minLevel
    local progressPercent
    if (inv.analyze.setsPkg.minLevel == maxLevel) then
      progressPercent = 100
    else
      progressPercent = levelsChecked / totalLevels * 100
    end -- if
    if (levelsChecked % 10 == 0) or (currentLevel == maxLevel) then
      dbot.print("@WEquipment analysis of \"@C" .. inv.analyze.setsPkg.priorityName .. "@W\": @G" ..
                 string.format("%3d", progressPercent) .. "%")

      if (currentLevel == maxLevel) then
        dbot.print("@W\nPreparing analysis report (this can take up to a minute)...")
      end -- if

      wait.time(0.1)
    end -- if

    -- Wait for createCR to finish (signaled by inv.set.createPkg becoming
    -- nil).  Watching the table entry was unreliable -- a pre-existing
    -- set looked identical to a freshly completed one -- and depended on
    -- the just-removed premature nil at the top of inv.set.create.
    local totTime = 0
    local timeout = 10
    while (inv.set.createPkg ~= nil) do
      wait.time(drlSpinnerPeriodDefault)
      totTime = totTime + drlSpinnerPeriodDefault
      if (totTime > timeout) then
        dbot.error("inv.analyze.setsCR: Failed to analyze \"" .. inv.analyze.setsPkg.priorityName ..
                   "\" priority for level " .. currentLevel .. ": timed out")
        retval = DRL_RET_TIMEOUT
        break
      end -- if
    end -- while

    -- If we had a problem with one set analysis, break out and don't continue
    if (retval == DRL_RET_TIMEOUT) then
      break
    end -- if
  end -- for

  dbot.prompt.show()

  -- Re-enable refreshes if we disabled them during this analysis
  if (didDisableRefresh) then
    inv.state = invStateIdle
  end -- if

  -- Save what we found
  inv.set.save()
  inv.statBonus.save()

  -- If the user gave us a callback, use it to let the caller know we are done
  if (inv.analyze.setsPkg.resultData ~= nil) then
    dbot.callback.default(inv.analyze.setsPkg.resultData, retval)
  end -- if

  -- Clean up and return
  inv.analyze.setsPkg = nil
  return retval
end -- inv.analyze.setsCR


function inv.analyze.delete(priorityName)
  inv.set.ensureLoaded()
  local retval = DRL_RET_SUCCESS

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.analyze.delete: missing priority name parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (inv.set.table[priorityName] == nil) then
    dbot.info("Analysis for priority \"@C" .. priorityName .. "@W\" does not exist")
    retval = DRL_RET_MISSING_ENTRY
  else
    dbot.info("Deleted set analysis for priority \"@C" .. priorityName .. "@W\"")
    inv.set.table[priorityName] = nil
    inv.set.save()
  end -- if

  return retval
end -- inv.analyze.delete


function inv.analyze.list()
  inv.set.ensureLoaded()
  local retval = DRL_RET_SUCCESS
  local numAnalyses = 0
  local sortedNames = {}

  -- Sort the analysis names
  for name, _ in pairs(inv.set.table) do
    table.insert(sortedNames, name)
  end -- for
  table.sort(sortedNames, function (v1, v2) return v1 < v2 end)

  dbot.print("@WSet analysis: @Gcomplete@W or @Ypartial@W")
  for _, name in ipairs(sortedNames) do
    local minLevel = 1 + 10 * dbot.gmcp.getTier()
    local maxLevel = minLevel + 200
    local analysisPrefix = "@G"
    local analysisSuffix = ""

    -- Scan through all levels for the analysis to see if any are missing at least one set
    for level = minLevel, maxLevel do
      if (inv.set.table[name][level] == nil) then
        analysisPrefix = "@Y"
        analysisSuffix = "@W -- Run \"@Gdinv analyze create " .. name .. "@W\" to complete the analysis"
        break
      end -- if
    end -- for

    dbot.print("  " .. analysisPrefix .. name .. analysisSuffix)

    numAnalyses = numAnalyses + 1
  end -- for

  if (numAnalyses == 0) then
    dbot.print("@W  No set analyses were detected.")
    retval = DRL_RET_MISSING_ENTRY
  end -- if

  dbot.print("")

  return retval
end -- inv.analyze.list


function inv.analyze.display(priorityName, wearableLoc, endTag)
  inv.set.ensureLoaded()
  local currentLevel
  local retval = DRL_RET_SUCCESS
  local lastSet = nil
  local setWearLoc

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.analyze.display: Priority name parameter is missing")
    return inv.tags.stop(invTagsAnalyze, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.set.table == nil) or (inv.set.table[priorityName] == nil) then
    dbot.warn("Analysis is not available for priority \"@C" .. priorityName ..
              "@W\".  Run \"@Gdinv analyze create " .. priorityName .. "@W\" to create it.")
    return inv.tags.stop(invTagsAnalyze, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  dbot.debug("inv.analyze.display: priority=\"" .. priorityName .. "\", locs=\"" .. wearableLoc .. "\"")

  local tierLevel  = 10 * dbot.gmcp.getTier()
  local startLevel = 1 + tierLevel
  local endLevel   = 201 + tierLevel
  for currentLevel = startLevel, endLevel do
    local didUpdateThisLevel = false

    for _,setWearLoc in pairs(inv.wearLoc) do
     if (wearableLoc == nil) or (wearableLoc == "") or dbot.isWordInString(setWearLoc, wearableLoc) then
        local set = inv.set.table[priorityName][currentLevel]

        -- Find the closest previous level that has a completed analysis.  If someone only analyzes
        -- every N levels, then the closest earlier analysis will be N levels prior.
        local prevSet
        for prevIdx = currentLevel - 1, startLevel, -1 do
          prevSet = inv.set.table[priorityName][prevIdx]
          if (prevSet ~= nil) then
            break
          end -- if
        end -- for

        if (set ~= nil) and (set[setWearLoc] ~= nil) then
          local objId = tonumber(set[setWearLoc].id or "")
          local prevObjId
          if (prevSet ~= nil) and (prevSet[setWearLoc] ~= nil) then
            prevObjId = tonumber(prevSet[setWearLoc].id or "")
          end -- if

          -- Display the item if this is our first level or if something changed from the previous level
          if (objId ~= nil) and ((objId ~= prevObjId) or (currentLevel == startLevel)) then
            if (didUpdateThisLevel == false) then
              didUpdateThisLevel = true

              dbot.print(string.format("\n@Y%s@W Level %3d @Y%s@s",
                                       string.rep("-", 44), currentLevel, string.rep("-", 44)))
              inv.items.displayLastType = "" -- kludge to force print the display header
            end -- if

            -- If an item was just replaced, give info on it so that we can compare it to the new item
            if (currentLevel ~= startLevel) and (prevObjId ~= nil) then
              inv.items.displayItem(prevObjId, invDisplayVerbosityDiffRemove, setWearLoc)
            end -- if

            inv.items.displayItem(objId, invDisplayVerbosityDiffAdd, setWearLoc)

          end -- if
        end -- if

      end -- if
    end -- for
  end -- for

  return inv.tags.stop(invTagsAnalyze, endTag, retval)
end -- inv.analyze.display



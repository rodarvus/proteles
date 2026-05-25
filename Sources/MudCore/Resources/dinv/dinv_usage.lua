----------------------------------------------------------------------------------------------------
--
-- Module to scan equipment sets for items matching a query and then provide usage information
-- for those items.  This includes listing all equipment sets that use the item and at what level(s)
-- the item is used.
--
-- dinv usage <priority name> <query>
--
-- inv.usage.display(priorityName, query, endTag)
-- inv.usage.displayCR()
-- inv.usage.displayItem(priorityName, objId, doDisplayUnused)
-- inv.usage.get(priorityName, objId)
--
----------------------------------------------------------------------------------------------------

inv.usage            = {}
inv.usage.displayPkg = nil

function inv.usage.display(priorityName, query, endTag)
  inv.set.ensureLoaded()

  if (priorityName == nil) or (query == nil) then
    dbot.error("inv.usage.display: input parameters are nil!")
    return inv.tags.stop(invTagsUsage, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.usage.displayPkg ~= nil) then
    dbot.info("Skipping display of item usage: another request is in progress")
    return inv.tags.stop(invTagsUsage, endTag, DRL_RET_BUSY)
  end -- if

  inv.usage.displayPkg              = {}
  inv.usage.displayPkg.priorityName = priorityName
  inv.usage.displayPkg.query        = query
  inv.usage.displayPkg.endTag       = endTag

  wait.make(inv.usage.displayCR)

  return DRL_RET_SUCCESS
end -- inv.usage.display


function inv.usage.displayCR()

  if (inv.usage.displayPkg == nil) then
    dbot.error("inv.usage.displayCR: inv.usage.displayPkg is nil!")
    return DRL_RET_INTERNAL_ERROR
  end -- if    

  local retval  
  local idArray
  local priorityName = inv.usage.displayPkg.priorityName or ""
  local query        = inv.usage.displayPkg.query or ""
  local endTag       = inv.usage.displayPkg.endTag

  -- Get an array of IDs for items that match the specified query
  idArray, retval = inv.items.searchCR(query)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.usage.displayCR: failed to search inventory table: " .. dbot.retval.getString(retval))

  -- Let the user know if no items matched their query
  elseif (idArray == nil) or (#idArray == 0) then
    dbot.info("No match found for usage query: \"" .. query .. "\"")

  else
    -- Sort the items in the array before we display them
    inv.items.sort(idArray, { { field = invStatFieldType,     isAscending = true },
                              { field = invStatFieldLevel,    isAscending = true },
                              { field = invStatFieldWearable, isAscending = true },
                              { field = invStatFieldName,     isAscending = true } })

    -- Display the items!
    for _, id in ipairs(idArray) do
      local wearableField = inv.items.getStatField(id, invStatFieldWearable)
      local typeField     = inv.items.getStatField(id, invStatFieldType)

      -- Only consider an item available to be used if it has a wearable location,
      -- is not a potion, pill, or food, and if it is not both a treasure and hold item.
      if (wearableField ~= nil) and 
         (typeField ~= invmon.typeStr[invmonTypePotion]) and 
         (typeField ~= invmon.typeStr[invmonTypePill]) and 
         (typeField ~= invmon.typeStr[invmonTypeFood]) and
         ((typeField ~= invmon.typeStr[invmonTypeTreasure]) or 
          (wearableField ~= inv.wearLoc[invWearableLocHold])) then

        if (priorityName == "all") then
          for priority, _ in pairs(inv.priority.table) do
            inv.usage.displayItem(priority, id, true)
          end -- for
        elseif (priorityName == "allUsed") then
          for priority, _ in pairs(inv.priority.table) do
            inv.usage.displayItem(priority, id, false)
          end -- for
        else
          inv.usage.displayItem(priorityName, id, true)
        end -- if
      end -- if
    end -- for

  end -- if

  -- Clean up and return
  inv.usage.displayPkg = nil
  return inv.tags.stop(invTagsUsage, endTag, retval)
end -- inv.usage.displayCR


function inv.usage.displayItem(priorityName, objId, doDisplayUnused)

  -- NOTE: The name/ID formatting below is similar to inv.items.displayItem but differs in maxNameLen
  -- (44 vs 24), ID display conditions, and diff mode prefixes. Extracting a shared helper would
  -- require 3-4 parameters for ~30 lines of savings — not worth the complexity.

  local colorName = inv.items.getField(objId, invFieldColorName) or "Unknown"
  local maxNameLen = 44

  -- We color-code the ID field as follows: unidentified = red, partial ID = yellow, full ID = green
  local formattedId = ""
  local colorizedId = ""
  local idPrefix = DRL_ANSI_WHITE
  local idSuffix = DRL_ANSI_WHITE
  local idLevel = inv.items.getField(objId, invFieldIdentifyLevel)
  if (idLevel ~= nil) then
    if (idLevel == invIdLevelNone) then
      idPrefix = DRL_ANSI_RED
    elseif (idLevel == invIdLevelPartial) then
      idPrefix = DRL_ANSI_YELLOW
    elseif (idLevel == invIdLevelFull) then
      idPrefix = DRL_ANSI_GREEN
    end -- if

    formattedId = "(" .. objId .. ") "
    colorizedId = idPrefix .. formattedId .. idSuffix
  end -- if

  -- Format the name field for the stat display.  This is complicated because we have a fixed
  -- number of spaces reserved for the field but color codes could take up some of those spaces.
  -- We iterate through the string byte by byte checking the length of the non-colorized equivalent
  -- to see when we've hit the limit that we can print.
  local formattedName = ""
  local index = 0
  while (#strip_colours(formattedName) < maxNameLen - #formattedId) and (index < 50) do
    formattedName = string.sub(colorName, 1, maxNameLen - #formattedId + index)

    -- It's possible for an item to have "%@" as part of its name (e.g., Roar of Victory).  This bombs
    -- when we try to display it because our print routine interprets it as a single format option.  We
    -- replace it with doubled % so that the print routine knows it is a literal.
    formattedName = string.gsub(formattedName, "%%@", "%%%%@")
    index = index + 1
  end

  if (#strip_colours(formattedName) < maxNameLen - #formattedId) then
    formattedName = formattedName .. string.rep(" ", maxNameLen - #strip_colours(formattedName) - #formattedId)
  end -- if
  -- The trimmed name could end on an "@" which messes up color codes and spacing
  formattedName = string.gsub(formattedName, "@$", " ") .. " " .. DRL_XTERM_GREY
  formattedName = formattedName .. colorizedId 

  local levelUsage  = inv.usage.get(priorityName, objId)
  local itemLevel   = inv.items.getStatField(objId, invStatFieldLevel) or "N/A"
  local itemType    = DRL_ANSI_YELLOW .. (inv.items.getStatField(objId, invStatFieldType) or "No Type") ..
                      DRL_ANSI_WHITE
  local levelStr    = ""
  local levelPrefix = "@G"
  local levelSuffix = "@W"

  if (levelUsage == nil) or (#levelUsage == 0) then
    levelStr    = DRL_ANSI_RED .. "Unused"
    levelPrefix = "@R"
  else
    levelStr = DRL_ANSI_GREEN
    -- Convert the list of levels into a string with ranges
    for i = 1, #levelUsage do
      -- If we have consecutive numbers on either side, we are in a range and can whack this item
      if (levelUsage[i - 1] ~= nil) and 
         ((levelUsage[i] == levelUsage[i - 1] + 1) or (levelUsage[i - 1] == 0 )) and
         (levelUsage[i + 1] ~= nil) and (levelUsage[i] == levelUsage[i + 1] - 1) then
        levelUsage[i] = 0
      end -- if
    end -- for

    local inRange = false
    for i = 1, #levelUsage do
      if (inRange == false) then
        if (levelUsage[i] == 0) then
          levelStr = levelStr .. "-"
          inRange = true
        elseif (i == 1) then
          levelStr = levelStr .. levelUsage[i]
        else
          levelStr = levelStr .. " " .. levelUsage[i]
        end -- if
      elseif (levelUsage[i] ~= 0) then
          levelStr = levelStr .. levelUsage[i]
          inRange = false
      end -- if
    end -- for
  end -- if

  -- Display the result for this item/priority if it is used or if the user wants to display unused items
  if ((levelUsage ~= nil) and (#levelUsage > 0)) or doDisplayUnused then
    local formattedLevel = string.format("%s%3d%s ", levelPrefix, itemLevel, levelSuffix)
    dbot.print(formattedLevel .. formattedName .. itemType .. " " .. priorityName .. " " .. levelStr)
  end -- if
end -- inv.usage.displayItem


-- Returns an array of levels in which the item is used by the specified priority
function inv.usage.get(priorityName, objId)
  if (priorityName == nil) then
    dbot.warn("inv.usage.get: priorityName parameter is nil!")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  objId = tonumber(objId or "")
  if (objId == nil) then
    dbot.warn("inv.usage.get: objId parameter is not a number")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  dbot.debug("Usage: priority=\"" .. priorityName .. "\", objId=" .. objId)

  local startLevel = tonumber(inv.items.getStatField(objId, invStatFieldLevel) or "")
  local endLevel   = 201 + 10 * dbot.gmcp.getTier()
  local wearTypes  = inv.items.getStatField(objId, invStatFieldWearable) or ""
  local levelArray = {}

  -- wearTypes is a list of locations an item might be at (e.g., a portal might be hold or portal)
  for wearType in wearTypes:gmatch("%S+") do
    -- wearType is a general location (e.g., wrist, finger, etc.)
    -- wearLoc is a specific location of wearType (e.g., lwrist, rfinger, etc.)
    --
    -- Scan through every possible wearLoc in the priority at the specified level to
    -- see if the current object is at that location.  If it is, remember it by putting
    -- the level it is used in an array that we return to the caller.
    if (wearType ~= nil) and (inv.wearables[wearType] ~= nil) then
      for _, wearLoc in ipairs(inv.wearables[wearType]) do
        if (wearLoc ~= nil) and (startLevel ~= nil) and (inv.set.table[priorityName] ~= nil) then
          for level = startLevel, endLevel do
            if (inv.set.table[priorityName][level] ~= nil) and 
               (inv.set.table[priorityName][level][wearLoc] ~= nil) and
               (inv.set.table[priorityName][level][wearLoc].id == objId) then
              table.insert(levelArray, level)
            end -- if
          end -- for
        end -- if
      end -- for
    end -- if
  end -- for

  return levelArray, DRL_RET_SUCCESS
end -- inv.usage.get



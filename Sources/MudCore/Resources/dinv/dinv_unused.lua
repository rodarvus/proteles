----------------------------------------------------------------------------------------------------
--
-- Module to list owned wearable items that are not part of any analyzed equipment set.  This is
-- useful for identifying gear that could be sold, donated, or junked.
--
-- An item is considered "part of a priority" if it appears in the priority's analyzed sets table
-- (populated by "dinv analyze create <priority>") at any level.  All other owned wearables are
-- reported as unused.
--
-- dinv unused <priority name | all> [nokeep]
--
-- inv.unused.display(priorityName, nokeep, endTag)
-- inv.unused.displayCR()
-- inv.unused.displayItem(objId)
-- inv.unused.hasKeepFlag(objId)
-- inv.unused.isSnapshotItem(objId)
-- inv.unused.priorityHasSets(priorityName)
-- inv.unused.partitionPriorities()
-- inv.unused.collectUsedIds(priorities)
-- inv.unused.isOwnedLocation(objLoc)
-- inv.unused.isCandidate(objId, usedIds, nokeep)
--
----------------------------------------------------------------------------------------------------

inv.unused            = {}
inv.unused.displayPkg = nil

-- Item types that are never part of equipment sets (consumables, portals, keys, misc).
-- String literals are used here rather than invmon.typeStr[...] because the dbot module
-- (which populates invmon.typeStr) loads after this file; these strings must stay in sync
-- with invmon.typeStr in dinv_dbot.lua.
inv.unused.excludedTypes =
{
  ["Potion"]       = true,
  ["Pill"]         = true,
  ["Food"]         = true,
  ["Scroll"]       = true,
  ["Wand"]         = true,
  ["Staff"]        = true,
  ["Portal"]       = true,
  ["Key"]          = true,
  ["Beacon"]       = true,
  ["Giftcard"]     = true,
  ["Drink"]        = true,
  ["Fountain"]     = true,
  ["Trash"]        = true,
  ["Furniture"]    = true,
  ["Boat"]         = true,
  ["Mobcorpse"]    = true,
  ["Playercorpse"] = true,
  ["Campfire"]     = true,
  ["Forge"]        = true,
  ["Runestone"]    = true,
  ["Raw material"] = true,
  ["None"]         = true,
  ["Unused"]       = true,
  ["Container"]    = true,
}

-- Named object locations that indicate the character owns the item (vs. tracked shop templates).
-- Worn items use a wear-loc name (e.g., "head", "body", "light") rather than a single "worn"
-- string, and items inside a container use the container's numeric objId; both are handled
-- separately in inv.unused.isOwnedLocation below.
inv.unused.ownedLocations =
{
  [invItemLocInventory] = true,
  [invItemLocVault]     = true,
  [invItemLocKeyring]   = true,
  [invItemLocAuction]   = true,
}


function inv.unused.display(priorityName, nokeep, endTag)
  inv.set.ensureLoaded()

  if (priorityName == nil) or (priorityName == "") then
    dbot.error("inv.unused.display: input parameters are nil!")
    return inv.tags.stop(invTagsUnused, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.unused.displayPkg ~= nil) then
    dbot.info("Skipping display of unused items: another request is in progress")
    return inv.tags.stop(invTagsUnused, endTag, DRL_RET_BUSY)
  end -- if

  local priorities
  local label

  if (priorityName == "all") then
    local analyzed, skipped = inv.unused.partitionPriorities()

    if (#analyzed == 0) then
      dbot.info("No priorities have analyze data.  Run \"" .. pluginNameCmd ..
                " analyze create <priority>\" first.")
      return inv.tags.stop(invTagsUnused, endTag, DRL_RET_UNINITIALIZED)
    end -- if

    dbot.print("@WConsidering " .. #analyzed .. " analyzed " ..
               ((#analyzed == 1) and "priority: @G" or "priorities: @G") ..
               table.concat(analyzed, ", ") .. "@W")
    if (#skipped > 0) then
      dbot.print("@W" .. #skipped .. " " ..
                 ((#skipped == 1) and "priority ignored" or "priorities ignored") ..
                 " (no analyze data).  Run \"" .. pluginNameCmd ..
                 " priority list\" to see all.@W")
    end -- if

    priorities = analyzed
    label      = "any analyzed priority"
  else
    if (inv.priority.table[priorityName] == nil) then
      dbot.info("Priority \"" .. priorityName .. "\" does not exist")
      return inv.tags.stop(invTagsUnused, endTag, DRL_RET_MISSING_ENTRY)
    end -- if

    if (not inv.unused.priorityHasSets(priorityName)) then
      dbot.info("No analyze data for \"" .. priorityName .. "\".  Run \"" .. pluginNameCmd ..
                " analyze create " .. priorityName .. "\" first.")
      return inv.tags.stop(invTagsUnused, endTag, DRL_RET_UNINITIALIZED)
    end -- if

    priorities = { priorityName }
    label      = "\"" .. priorityName .. "\""
  end -- if

  inv.unused.displayPkg            = {}
  inv.unused.displayPkg.priorities = priorities
  inv.unused.displayPkg.nokeep     = nokeep
  inv.unused.displayPkg.label      = label
  inv.unused.displayPkg.endTag     = endTag

  wait.make(inv.unused.displayCR)

  return DRL_RET_SUCCESS
end -- inv.unused.display


function inv.unused.displayCR()
  if (inv.unused.displayPkg == nil) then
    dbot.error("inv.unused.displayCR: inv.unused.displayPkg is nil!")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local priorities = inv.unused.displayPkg.priorities
  local nokeep     = inv.unused.displayPkg.nokeep
  local label      = inv.unused.displayPkg.label
  local endTag     = inv.unused.displayPkg.endTag

  -- Collect the set of obj_ids used by any of the considered priorities at any level/wear-loc
  local usedIds = inv.unused.collectUsedIds(priorities)

  -- Walk the inventory table and collect items that pass all exclusion filters
  local candidateIds = {}
  for objId, _ in pairs(inv.items.table) do
    if inv.unused.isCandidate(objId, usedIds, nokeep) then
      table.insert(candidateIds, objId)
    end -- if
  end -- for

  if (#candidateIds == 0) then
    dbot.info("No unused items found for " .. label .. ".")
    inv.unused.displayPkg = nil
    return inv.tags.stop(invTagsUnused, endTag, DRL_RET_SUCCESS)
  end -- if

  -- Sort by type, then level, then wearable location, then name -- same ordering as "dinv usage"
  inv.items.sort(candidateIds, { { field = invStatFieldType,     isAscending = true },
                                 { field = invStatFieldLevel,    isAscending = true },
                                 { field = invStatFieldWearable, isAscending = true },
                                 { field = invStatFieldName,     isAscending = true } })

  for _, id in ipairs(candidateIds) do
    inv.unused.displayItem(id)
  end -- for

  local suffix = (#candidateIds == 1) and "" or "s"
  dbot.print("@W" .. #candidateIds .. " item" .. suffix .. " not part of " .. label .. ".@W")

  inv.unused.displayPkg = nil
  return inv.tags.stop(invTagsUnused, endTag, DRL_RET_SUCCESS)
end -- inv.unused.displayCR


-- Returns true if the item has the "keep" flag set.  Flags are stored as a space-separated string
-- with optional trailing commas (e.g., "keep glow, hum").
function inv.unused.hasKeepFlag(objId)
  local flags = inv.items.getStatField(objId, invStatFieldFlags) or ""

  for element in flags:gmatch("%S+") do
    element = string.gsub(element, ",", "")
    if (string.lower(element) == "keep") then
      return true
    end -- if
  end -- for

  return false
end -- inv.unused.hasKeepFlag


-- Returns true if the item appears in any snapshot
function inv.unused.isSnapshotItem(objId)
  if (inv.snapshot == nil) or (inv.snapshot.table == nil) then
    return false
  end -- if

  for _, equipSet in pairs(inv.snapshot.table) do
    for _, itemData in pairs(equipSet) do
      if (itemData ~= nil) and (itemData.id == objId) then
        return true
      end -- if
    end -- for
  end -- for

  return false
end -- inv.unused.isSnapshotItem


-- Returns true if the priority has at least one entry in the analyzed sets table
function inv.unused.priorityHasSets(priorityName)
  if (inv.set.table == nil) or (inv.set.table[priorityName] == nil) then
    return false
  end -- if

  return (next(inv.set.table[priorityName]) ~= nil)
end -- inv.unused.priorityHasSets


-- Split all known priorities into two lists: those that have analyze data and those that do not.
-- Returns both lists sorted alphabetically.
function inv.unused.partitionPriorities()
  local analyzed = {}
  local skipped  = {}

  for priorityName, _ in pairs(inv.priority.table) do
    if inv.unused.priorityHasSets(priorityName) then
      table.insert(analyzed, priorityName)
    else
      table.insert(skipped, priorityName)
    end -- if
  end -- for

  table.sort(analyzed)
  table.sort(skipped)

  return analyzed, skipped
end -- inv.unused.partitionPriorities


-- Collect the set of obj_ids used by any of the given priorities at any level/wear-loc.
-- Returns a { objId = true } map.  Shared by inv.unused.displayCR (the "dinv unused" command)
-- and the "unused" search query tag.
function inv.unused.collectUsedIds(priorities)
  local usedIds = {}
  if (priorities == nil) or (inv.set.table == nil) then return usedIds end
  for _, priorityName in ipairs(priorities) do
    if (inv.set.table[priorityName] ~= nil) then
      for _, levelSets in pairs(inv.set.table[priorityName]) do
        for _, itemData in pairs(levelSets) do
          if (itemData ~= nil) and (itemData.id ~= nil) then
            usedIds[itemData.id] = true
          end -- if
        end -- for
      end -- for
    end -- if
  end -- for
  return usedIds
end -- inv.unused.collectUsedIds


-- Returns true if objLoc (a string name or numeric container objId) resolves to one of the
-- character's owned locations.  Walks the container chain in case the item sits inside a
-- container that itself sits inside another container, etc.  Returns false for "uninitialized",
-- "shopkeeper", chains that terminate at either, and chains where a container is missing
-- from inv.items.table.
function inv.unused.isOwnedLocation(objLoc)
  -- Lazy-init the wear-loc name set: dinv_data.lua loads after this file, so inv.wearLoc
  -- isn't available at module-load time.
  if (inv.unused.wearLocNames == nil) then
    inv.unused.wearLocNames = {}
    if (inv.wearLoc ~= nil) then
      for _, name in pairs(inv.wearLoc) do
        inv.unused.wearLocNames[name] = true
      end -- for
    end -- if
  end -- if

  local visited = {}
  while (objLoc ~= nil) do
    if (inv.unused.ownedLocations[objLoc] == true) or
       (inv.unused.wearLocNames[objLoc] == true) then
      return true
    end -- if

    -- Anything non-numeric that didn't match above (e.g., "uninitialized", "shopkeeper",
    -- or any unknown string) is not owned.
    if (type(objLoc) ~= "number") then return false end

    -- Numeric: treat as a container objId and chase the chain.  Visited set guards against
    -- pathological cycles.
    if (visited[objLoc]) then return false end
    visited[objLoc] = true

    local container = inv.items.table[objLoc]
    if (container == nil) then return false end

    objLoc = container[invFieldObjLoc]
  end -- while

  return false
end -- inv.unused.isOwnedLocation


-- Apply the full set of exclusion filters for the "sell/donate/junk" use case
function inv.unused.isCandidate(objId, usedIds, nokeep)
  -- Must have a wearable location (filters consumables, keys, portals, etc. without a slot)
  local wearable = inv.items.getStatField(objId, invStatFieldWearable)
  if (wearable == nil) or (wearable == "") then return false end

  -- Must be an equipment type (not consumable, container, or other non-gear)
  local itemType = inv.items.getStatField(objId, invStatFieldType)
  if (itemType == nil) or (inv.unused.excludedTypes[itemType] == true) then return false end

  -- Must be owned by the character (not a tracked shop template).  An item is owned if its
  -- location is a named owned slot, a wear-loc name (worn items), or it sits in a container
  -- whose own location resolves through the chain to one of the above.
  if not inv.unused.isOwnedLocation(inv.items.getField(objId, invFieldObjLoc)) then
    return false
  end -- if

  -- Exclude items referenced by any snapshot
  if inv.unused.isSnapshotItem(objId) then return false end

  -- Optionally exclude items flagged KEEP
  if nokeep and inv.unused.hasKeepFlag(objId) then return false end

  -- Finally: the item must not appear in any of the considered priorities' sets
  if (usedIds[objId] == true) then return false end

  return true
end -- inv.unused.isCandidate


-- Display one unused item line.  Format mirrors "dinv usage" minus the priority/level-usage column.
function inv.unused.displayItem(objId)
  local colorName  = inv.items.getField(objId, invFieldColorName) or "Unknown"
  local maxNameLen = 44

  -- Color-code the object ID by identify level: unidentified = red, partial = yellow, full = green
  local formattedId = ""
  local colorizedId = ""
  local idPrefix    = DRL_ANSI_WHITE
  local idSuffix    = DRL_ANSI_WHITE
  local idLevel     = inv.items.getField(objId, invFieldIdentifyLevel)
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

  -- Format the name field to a fixed width while preserving color codes
  local formattedName = ""
  local index         = 0
  while (#strip_colours(formattedName) < maxNameLen - #formattedId) and (index < 50) do
    formattedName = string.sub(colorName, 1, maxNameLen - #formattedId + index)
    -- Escape literal %@ sequences so dbot.print doesn't treat them as format options
    formattedName = string.gsub(formattedName, "%%@", "%%%%@")
    index = index + 1
  end -- while

  if (#strip_colours(formattedName) < maxNameLen - #formattedId) then
    formattedName = formattedName ..
                    string.rep(" ", maxNameLen - #strip_colours(formattedName) - #formattedId)
  end -- if
  -- A trimmed name can end in "@" which would swallow the following color code
  formattedName = string.gsub(formattedName, "@$", " ") .. " " .. DRL_XTERM_GREY
  formattedName = formattedName .. colorizedId

  local itemLevel = inv.items.getStatField(objId, invStatFieldLevel) or "N/A"
  local itemType  = DRL_ANSI_YELLOW ..
                    (inv.items.getStatField(objId, invStatFieldType) or "No Type") ..
                    DRL_ANSI_WHITE
  local objLoc    = inv.items.getField(objId, invFieldObjLoc) or "unknown"

  local formattedLevel = string.format("@G%3d@W ", itemLevel)
  dbot.print(formattedLevel .. formattedName .. itemType .. " @C" .. objLoc .. "@W")
end -- inv.unused.displayItem

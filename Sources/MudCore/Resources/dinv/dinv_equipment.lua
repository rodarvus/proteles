----------------------------------------------------------------------------------------------------
--
-- Module to manage weapon-only equipment sets
--
-- dinv weapon [next | <priority> <damType list>]
--
-- inv.weapon.use(priorityName, damTypes, endTag)
-- inv.weapon.next(endTag)
--
----------------------------------------------------------------------------------------------------

inv.weapon = {}
inv.weapon.priorityName = "weaponSet"

function inv.weapon.use(priorityName, damTypes, endTag)
  inv.set.ensureLoaded()
  local retval = DRL_RET_SUCCESS
  local weaponPriority = {}

  if (priorityName == nil) or (priorityName == "") then
    dbot.warn("inv.weapon.use: Missing priority name")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (damTypes == nil) or (damTypes == "") then
    dbot.warn("inv.weapon.use: Missing list of requested damage types")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  -- Remove any previous (and stale) weapon priority
  if (inv.priority.table[inv.weapon.priorityName] ~= nil) then
    retval = inv.priority.remove(inv.weapon.priorityName)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.weapon.use: Failed to remove weapon priority: " .. dbot.retval.getString(retval))
      return inv.tags.stop(invTagsSet, endTag, retval)
    end -- if
  end -- if

  -- Clone the specified priority so that we can tweak the clone and add damage type preferences
  retval = inv.priority.clone(priorityName, inv.weapon.priorityName, false, nil)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.weapon.use: Failed to clone priority \"" .. priorityName .. "\": " ..
              dbot.retval.getString(retval))
    return inv.tags.stop(invTagsSet, endTag, retval)
  end -- if

  local damTypesToUse = string.lower(damTypes)
  local allDamTypes = dbot.arrayConcat(dbot.physicalTypes, dbot.magicalTypes)

  -- For each priority block in the priority, specify if each possible damage type is allowed
  for _, priBlock in ipairs(inv.priority.table[inv.weapon.priorityName] or {}) do
    for _, damType in ipairs(allDamTypes) do
      if dbot.isWordInString(damType, damTypesToUse)                                    or
         dbot.isWordInString("all", damTypesToUse)                                      or
         (dbot.isWordInString("phys", damTypesToUse) and dbot.isPhysical(damType))      or
         (dbot.isWordInString("magic", damTypesToUse) and dbot.isMagical(damType))      or
         (dbot.isWordInString("physical", damTypesToUse) and dbot.isPhysical(damType))  or
         (dbot.isWordInString("magical", damTypesToUse) and dbot.isMagical(damType))    then
        priBlock.priorities["~" .. damType] = 0
      else
        priBlock.priorities["~" .. damType] = 1
      end -- if
    end -- for
  end -- for

  -- Persist the damtype exclusions we just set.  inv.priority.clone above already
  -- wrote the unmodified copy to disk, but the loop above mutates the priority
  -- blocks in memory only -- without this save the on-disk weaponSet wouldn't
  -- match the one that generated the equipment set, and "dinv weapon next" on
  -- the next session would start from the wrong baseline.
  inv.priority.save()

  -- Wear the set that matches the weapon priority
  return inv.set.createAndWear(inv.weapon.priorityName, dbot.gmcp.getLevel(),
                               inv.set.createIntensity, endTag)
end -- inv.weapon.use


function inv.weapon.next(endTag)
  local retval
  local level = dbot.gmcp.getLevel()

  -- Check if the weapon priority exists and has an associated weapon set
  if (inv.priority.table[inv.weapon.priorityName] == nil)   or
     (inv.set.table[inv.weapon.priorityName] == nil)        or
     (inv.set.table[inv.weapon.priorityName][level] == nil) then
    dbot.info("Skipped weapon request: Use \"@Gdinv weapon <priority> <damage types>@W\" to specify types")
    return DRL_RET_UNINITIALIZED
  end -- if

  local wielded = inv.set.table[inv.weapon.priorityName][level].wielded
  local second  = inv.set.table[inv.weapon.priorityName][level].second
  local currentDamType = ""

  if (wielded ~= nil) then
    currentDamType = inv.items.getStatField(wielded.id, invStatFieldDamType)
  elseif (second ~= nil) then
    currentDamType = inv.items.getStatField(second.id, invStatFieldDamType)
  else
    dbot.info("Skipping next weapon request: No allowable weapon sets remain")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  if (currentDamType == nil) then
    dbot.info("Skipping next weapon request: Unknown damage type -- You may need an inventory refresh")
    return inv.tags.stop(invTagsSet, endTag, DRL_RET_UNINITIALIZED)
  end -- if

  dbot.debug("inv.weapon.next: Current dam type is: \"" .. currentDamType .. "\"")

  -- Remove the current primary dam type for each priority block in the weapon set priority
  for _, priBlock in ipairs(inv.priority.table[inv.weapon.priorityName] or {}) do
    priBlock.priorities["~" .. string.lower(currentDamType)] = 1
  end -- for

  -- Persist the new exclusion so the on-disk weaponSet stays in sync with the
  -- set we're about to wear; without this, a reload would lose the running
  -- exclusion history and "weapon next" would cycle back through dam types
  -- the user has already rotated past.
  inv.priority.save()

  -- Wear the set that matches the updated weapon priority
  return inv.set.createAndWear(inv.weapon.priorityName, level, inv.set.createIntensity, endTag)

end -- inv.weapon.next


----------------------------------------------------------------------------------------------------
--
-- Module to manage snapshots of equipment sets
--
-- The inv.set module handles creating and wearing equipment sets automatically generated from a
-- priority weighting of stats.  That is probably what most people will use to manage equipment
-- sets.  However, it may be convenient to take a snapshot of what you are wearing at a particular
-- moment and easily go back to re-wear the exact same items at a later date.  That's where this
-- snapshot module comes in.
--
-- You can add and remove snapshots (big surprise) with the cleverly named inv.snapshot.add and
-- inv.snapshot.remove functions.  You can also re-wear the items from an existing snapshot by
-- calling inv.snapshot.wear.  The inv.snapshot.list function prints a listing of all existing
-- saved snapshots.  The inv.snapshot.display function prints details about a specific snapshot.
-- Easy peasy.
--
-- inv.snapshot.init.atActive()
-- inv.snapshot.fini(doSaveState)
--
-- inv.snapshot.save()
-- inv.snapshot.load()
-- inv.snapshot.reset()
--
-- inv.snapshot.add(snapshotName, endTag)
-- inv.snapshot.remove(snapshotName, endTag)
--
-- inv.snapshot.list(endTag)
-- inv.snapshot.display(snapshotName, endTag)
-- inv.snapshot.wear(snapshotName, endTag)
--
----------------------------------------------------------------------------------------------------

inv.snapshot           = {}
inv.snapshot.init      = {}
inv.snapshot.table     = {}


function inv.snapshot.init.atActive()
  local retval = DRL_RET_SUCCESS

  retval = inv.snapshot.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.snapshot.init.atActive: failed to load snapshot data from storage: " ..
              dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.snapshot.init.atActive


function inv.snapshot.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  if (doSaveState) then
    -- Save our current data
    retval = inv.snapshot.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.snapshot.fini: Failed to save inv.snapshot module data: " ..
                dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- inv.snapshot.fini


function inv.snapshot.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  if not inv.snapshot.table then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM snapshots")

    for snapName, equipSet in pairs(inv.snapshot.table) do
      for wearLoc, itemData in pairs(equipSet) do
        local query = string.format(
          "INSERT INTO snapshots (snapshot_name, wear_loc, obj_id, score) VALUES (%s, %s, %s, %s)",
          dinv_db.fixsql(snapName),
          dinv_db.fixsql(wearLoc),
          dinv_db.fixnum(itemData.id),
          dinv_db.fixnum(itemData.score))
        db:exec(query)
        if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
          dbot.warn("inv.snapshot.save: Failed to save snapshot " .. snapName)
          return DRL_RET_INTERNAL_ERROR
        end
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- inv.snapshot.save


function inv.snapshot.load()
  local db = dinv_db.handle
  if not db then
    inv.snapshot.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any snapshot rows exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM snapshots") do
    count = row.cnt
  end

  if count == 0 then
    inv.snapshot.table = {}
    return DRL_RET_SUCCESS
  end

  inv.snapshot.table = {}
  for row in db:nrows("SELECT snapshot_name, wear_loc, obj_id, score FROM snapshots") do
    if not inv.snapshot.table[row.snapshot_name] then
      inv.snapshot.table[row.snapshot_name] = {}
    end
    inv.snapshot.table[row.snapshot_name][row.wear_loc] = {
      id    = row.obj_id,
      score = row.score,
    }
  end

  return DRL_RET_SUCCESS
end -- inv.snapshot.load


function inv.snapshot.reset()
  inv.snapshot.table = {}

  return inv.snapshot.save()
end -- inv.snapshot.reset


function inv.snapshot.add(snapshotName, endTag)
  local retval = DRL_RET_SUCCESS
  local numItemsInSnap = 0
  local snap = {}

  if (snapshotName == nil) or (snapshotName == "") then
    dbot.warn("inv.snapshot.add: Missing snapshot name")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  for objId, _ in pairs(inv.items.table) do
    if inv.items.isWorn(objId) then
      local objLoc = inv.items.getField(objId, invFieldObjLoc) or ""

      if (objLoc ~= "") then
        snap[objLoc] = { id = objId, score = 0 } -- snapshots don't have scores but the set format needs them
        numItemsInSnap = numItemsInSnap + 1
      end -- if
    end -- if
  end -- for

  local suffix = ""
  if (numItemsInSnap ~= 1) then
    suffix = "s"
  end -- if

  if (numItemsInSnap > 0) then
    inv.snapshot.table[snapshotName] = snap
    dbot.info("Created \"@C" .. snapshotName .. "@W\" snapshot with " .. numItemsInSnap .. " item" .. suffix)

    retval = inv.snapshot.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.snapshot.remove: Failed to save snapshot table: " .. dbot.retval.getString(retval))
    end -- if
  else
    dbot.info("No items were added to snapshot \"@C" .. snapshotName .. "@W\"")
    retval = DRL_RET_MISSING_ENTRY
  end -- if

  return inv.tags.stop(invTagsSnapshot, endTag, retval)
end -- inv.snapshot.add


function inv.snapshot.remove(snapshotName, endTag)
  local retval = DRL_RET_SUCCESS

  if (snapshotName == nil) or (snapshotName == "") then
    dbot.warn("inv.snapshot.remove: Missing snapshot name")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.snapshot.table[snapshotName] == nil) then
    dbot.warn("inv.snapshot.remove: Failed to remove snapshot \"@C" .. snapshotName ..
              "@W\": it does not exist")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  -- Remove the snapshot
  inv.snapshot.table[snapshotName] = nil
  retval = inv.snapshot.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.snapshot.remove: Failed to save snapshot table: " .. dbot.retval.getString(retval))
  end -- if

  dbot.info("Removed snapshot \"@C" .. snapshotName .. "@W\"")

  return inv.tags.stop(invTagsSnapshot, endTag, retval)
end -- inv.snapshot.remove


-- print names of all snapshots
function inv.snapshot.list(endTag)
  local retval = DRL_RET_SUCCESS
  local numSnapshots = 0

  for snapName, snapSet in pairs(inv.snapshot.table) do
    if (numSnapshots == 0) then
      dbot.print("@WSaved Snapshots:")
    end -- if

    dbot.print("  @C" .. snapName)
    numSnapshots = numSnapshots + 1
  end -- for

  local suffix = ""
  if (numSnapshots ~= 1) then
    suffix = "s"
  end -- if
  dbot.info("Found " .. numSnapshots .. " saved snapshot" .. suffix)

  return inv.tags.stop(invTagsSnapshot, endTag, retval)
end -- inv.snapshot.list


function inv.snapshot.display(snapshotName, endTag)
  local retval = DRL_RET_SUCCESS

  if (snapshotName == nil) or (snapshotName == "") then
    dbot.warn("inv.snapshot.display: Missing snapshot name")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.snapshot.table[snapshotName] == nil) then
    dbot.warn("inv.snapshot.display: Failed to display snapshot \"@C" .. snapshotName ..
              "@W\": it does not exist")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  retval = inv.set.displaySet(snapshotName, nil, inv.snapshot.table[snapshotName], nil)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.snapshot.display: Failed to display snapshot \"@C" .. snapshotName ..
              "@W\": " .. dbot.retval.getString(retval))
  end -- if

  return inv.tags.stop(invTagsSnapshot, endTag, retval)
end -- inv.snapshot.display


inv.snapshot.wearPkg = nil
function inv.snapshot.wear(snapshotName, endTag)
  local retval = DRL_RET_SUCCESS

  if (snapshotName == nil) or (snapshotName == "") then
    dbot.warn("inv.snapshot.wear: Missing snapshot name")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (inv.snapshot.table[snapshotName] == nil) then
    dbot.warn("inv.snapshot.wear: Failed to wear snapshot \"@C" .. snapshotName ..
              "@W\": it does not exist")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  if (inv.snapshot.wearPkg ~= nil) then
    dbot.info("Skipping request to wear snapshot \"@C" .. snapshotName .. "@W\": " ..
              dbot.retval.getString(retval))
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_BUSY)
  end -- if

  inv.snapshot.wearPkg              = {}
  inv.snapshot.wearPkg.snapshotName = snapshotName
  inv.snapshot.wearPkg.endTag       = endTag

  wait.make(inv.snapshot.wearCR)

  return retval
end -- inv.snapshot.wear


function inv.snapshot.wearCR()
  local retval = DRL_RET_SUCCESS

  if (inv.snapshot.wearPkg == nil) then
    dbot.error("inv.snapshot.wearCR: wear package is nil!")
    return inv.tags.stop(invTagsSnapshot, "", DRL_RET_INTERNAL_ERROR)
  end -- if

  local endTag = inv.snapshot.wearPkg.endTag
  local snapshotName = inv.snapshot.wearPkg.snapshotName

  if (inv.snapshot.table[snapshotName] == nil) then
    dbot.warn("inv.snapshot.wearCR: Failed to wear snapshot \"@C" .. snapshotName ..
              "@W\": it does not exist")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_MISSING_ENTRY)
  end -- if

  retval = inv.set.wear(inv.snapshot.table[snapshotName])
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.snapshot.wearCR: Failed to wear snapshot \"@C" .. snapshotName ..
              "@W\": " .. dbot.retval.getString(retval))
  end -- if

  -- Clean up and return
  inv.snapshot.wearPkg = nil
  return inv.tags.stop(invTagsSnapshot, endTag, retval)
end -- inv.snapshot.wearCR



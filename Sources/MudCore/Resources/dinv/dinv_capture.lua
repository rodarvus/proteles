-- Response ownership and staged observations. Parsers publish complete data;
-- their timeout/cleanup paths only discard an unfinished capture.
inv.items.inventoryRevision = 0
inv.items.earlyEvents = {}

function inv.items.abortCapture()
  local t = inv.items.trigger
  for _, key in ipairs({ "itemDataStartName", "itemDataStatsName", "itemIdStartName",
    "itemIdStatsName", "suppressWindsName", "idItemName" }) do
    if t[key] then EnableTrigger(t[key], false) end
  end
  if t.itemDataEndName then DeleteTrigger(t.itemDataEndName) end
  DeleteTrigger("dinv_snapshot_invalid_row")
  if t.itemIdEndName then DeleteTrigger(t.itemIdEndName) end
  inv.items.discoverPkg, inv.items.identifyPkg = nil, nil
end

function inv.items.cleanupRequest(op, retval)
  if retval == DRL_RET_SUCCESS then
    if op.identification then return op.identification.retval or DRL_RET_TIMEOUT end
    return retval
  end
  if not op.setupStarted then
    if op.identification and inv.items.identifyPkg == op.identification then inv.items.identifyPkg = nil end
    return retval
  end
  local t = inv.items.trigger
  if op.setupFn == inv.items.identifyAtomicSetup or op.setupFn == inv.items.identifyItemSetupFn then
    inv.items.trigger.itemIdEnd(false)
  elseif op.setupFn == inv.items.convertSetupFn then
    EnableTrigger(t.idItemName, false)
    inv.lastIdentifiedObjectId = nil
  elseif op.setupFn == dbot.wish.setupFn then
    EnableTrigger(dbot.wish.trigger.itemName, false)
    DeleteTrigger(dbot.wish.trigger.startName)
    dbot.wish.inProgress, dbot.wish.pending = false, nil
  elseif op.setupFn == inv.statBonus.setSetupFn then
    EnableTrigger(inv.statBonus.trigger.getName, false)
    DeleteTrigger(inv.statBonus.trigger.startName)
    inv.statBonus.bonusInProgress, inv.statBonus.pending = false, nil
  elseif op.setupFn == dbot.pagesize.setupFn then
    EnableTrigger(dbot.pagesize.trigger.getName, false)
  end
end

function inv.items.snapshotSetup(snapshot)
  inv.items.discoverPkg = snapshot
  snapshot.revision = inv.items.inventoryRevision
  EnableTrigger(inv.items.trigger.itemDataStartName, true)
  -- Well-formed rows are consumed by the normal sequence-0 trigger. Catch a
  -- truncated numeric row after it so it cannot silently become an empty scan.
  check(AddTriggerEx("dinv_snapshot_invalid_row", "^([0-9]+,.*)$",
    "inv.items.invalidSnapshotRow(\"%1\")", drlTriggerFlagsBaseline,
    custom_colour.NoChange, 0, "", "", sendto.script, 100))
end

function inv.items.invalidSnapshotRow(line)
  -- Some hosts continue plugin evaluation after a matching capture trigger.
  if line:match("^%d+,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*$") then return end
  local snapshot = inv.items.discoverPkg
  if snapshot and snapshot.started then inv.commands.cancel(snapshot.operation, DRL_RET_INVALID_PARAM) end
end

function inv.items.snapshotCleanup(op)
  local snapshot = op.setupData
  if inv.items.discoverPkg == snapshot then
    DeleteTrigger("dinv_snapshot_invalid_row")
    EnableTrigger(inv.items.trigger.itemDataStartName, false)
    EnableTrigger(inv.items.trigger.itemDataStatsName, false)
    DeleteTrigger(inv.items.trigger.itemDataEndName)
    inv.items.discoverPkg = nil
  end
end

function inv.items.snapshotCommit(snapshot)
  if snapshot.invalid or not snapshot.started then return DRL_RET_INTERNAL_ERROR end
  if snapshot.revision ~= inv.items.inventoryRevision then return DRL_RET_BUSY end
  local previous = inv.items.table
  local observed = inv.items.currentItems
  local recent, frequent = inv.cache.recent.table, inv.cache.frequent.table
  local candidate = dbot.table.getCopy(previous)
  inv.items.table = candidate
  inv.cache.recent.table = dbot.table.getCopy(recent)
  inv.cache.frequent.table = dbot.table.getCopy(frequent)
  inv.items.currentItems = observed and dbot.table.getCopy(observed) or {}
  local ok, retval = pcall(function()
    return dinv_db.transaction(function()
      for _, row in ipairs(snapshot.rows) do
        local rv = inv.items.trigger.applyItemData(unpack(row))
        if rv ~= DRL_RET_SUCCESS and rv ~= DRL_RET_UNSUPPORTED then return rv end
        local id = tonumber(row[1])
        if candidate[id] then
          local query = dinv_db.buildItemInsert("items", id, candidate[id])
          local db = dinv_db.handle
          if db and db:exec(query) ~= sqlite3.OK then return DRL_RET_INTERNAL_ERROR end
        end
      end
      return DRL_RET_SUCCESS
    end)
  end)
  if not ok or retval ~= DRL_RET_SUCCESS then
    inv.items.table, inv.items.currentItems = previous, observed
    inv.cache.recent.table, inv.cache.frequent.table = recent, frequent
    return DRL_RET_INTERNAL_ERROR
  end
  if not observed then inv.items.currentItems = nil end
  return DRL_RET_SUCCESS
end

function inv.items.observeChange(kind, args)
  inv.items.inventoryRevision = inv.items.inventoryRevision + 1
  if not inv.init.initializedActive then
    -- Bounded replay buffer. If it overflows, startup's full reconciliation is
    -- still authoritative; do not build up unbounded login traffic.
    if #inv.items.earlyEvents < 2000 then
      inv.items.earlyEvents[#inv.items.earlyEvents + 1] = { kind = kind, args = args }
    end
    return false
  end
  local id = tonumber(args[kind == "invmon" and 2 or 1])
  if id and inv.items.currentItems then inv.items.currentItems[id] = { discovered = true } end
  return true
end

function inv.items.replayEarlyEvents()
  local events = inv.items.earlyEvents
  inv.items.earlyEvents = {}
  for _, event in ipairs(events) do
    if event.kind == "invmon" then inv.items.trigger.invmon(unpack(event.args))
    else inv.items.trigger.itemDataStats(unpack(event.args)) end
  end
end

function inv.items.commitIdentification(package)
  local prior = inv.items.table[package.objId]
  if not prior or not package.observedId or not package.sawDetails then return DRL_RET_BUSY end
  local special = package.objLoc == invItemLocAuction or package.objLoc == invItemLocShopkeeper
  if not special and tonumber(package.observedId) ~= tonumber(package.objId) then return DRL_RET_BUSY end
  local candidate = dbot.table.getCopy(prior)
  inv.items.table[package.objId] = candidate
  local ok, retval = pcall(function()
    return dinv_db.transaction(function()
    for _, field in ipairs({invStatFieldStr, invStatFieldInt, invStatFieldWis,
      invStatFieldDex, invStatFieldCon, invStatFieldLuck}) do
      inv.items.setStatField(package.objId, field, 0)
    end
    for _, key in ipairs({"flagsContinuation", "affectModsContinuation", "keywordsContinuation",
      "nameContinuation"}) do inv.items.trigger[key] = false end
    inv.items.setField(package.objId, invFieldIdentifyLevel, invIdLevelNone)
    for _, line in ipairs(package.lines or {}) do inv.items.trigger.parseItemIdStats(line) end
      return inv.items.trigger.finishIdentification()
    end)
  end)
  if not ok or retval ~= DRL_RET_SUCCESS then
    inv.items.table[package.objId] = prior
    dbot.warn("Identification discarded: " .. tostring(retval))
    return DRL_RET_INTERNAL_ERROR
  end
  return DRL_RET_SUCCESS
end

function inv.cli.runtimeStatus(name, line, wildcards)
  if line and line:match("^dinv cancel") then
    inv.runtime.cancelAll(DRL_RET_HALTED)
    inv.runtime.scheduleBackground()
    dbot.info("Canceled pending dinv work; already-sent game commands cannot be recalled.")
    return
  end
  local tasks, queued = 0, 0
  for _ in pairs(inv.runtime.tasks) do tasks = tasks + 1 end
  for _, op in ipairs(inv.commands.queue) do if not op.done then queued = queued + 1 end end
  local phase = inv.init.initializedActive and "saved inventory loaded" or "waiting for character data"
  local current = inv.items.fullScanCompleted and not inv.items.isDirty() and inv.state == invStateIdle
  local freshness = current and "synchronized" or "synchronization pending"
  dbot.info(string.format("v%d.%04d: %s; %s", inv.version.pluginMajor,
    inv.version.pluginMinor, phase, freshness))
  local active = inv.commands.active
  dbot.info("Requests: " .. queued .. " queued; " .. tasks .. " workflows; active: " ..
    (active and (active.label .. " (" .. active.phase .. ")") or "none"))
  local prompt = dbot.prompt.isEnabled
  local period = tonumber(inv.config.table and inv.config.table.refreshPeriod)
  local automatic = period == nil and "not loaded" or period > 0 and "on" or "off"
  dbot.info("Observed prompt: " .. (prompt == nil and "unknown" or prompt and "on" or "off") ..
    "; automatic refresh: " .. automatic)
end

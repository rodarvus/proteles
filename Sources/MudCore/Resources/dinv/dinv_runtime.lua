-- Owned timers and continuations. Network requests are state machines in
-- dinv_commands.lua; long equipment/calculation workflows use the small
-- coroutine adapter here. No coroutine owns a client timer or a global queue.
inv.runtime = { timers = {}, tasks = {}, generation = 1, enabled = true }

function inv.runtime.now()
  if proteles and proteles.monotonic then return proteles.monotonic() end
  if utils and utils.timer then return utils.timer() end
  return os.time()
end

function inv.runtime.after(seconds, fn)
  local rt = inv.runtime
  local name = "dinv_runtime_" .. GetUniqueNumber()
  rt.timers[name] = { fn = fn, generation = rt.generation }
  local delay = math.max(tonumber(seconds) or 0, 0.01)
  local hours = math.floor(delay / 3600)
  local minutes = math.floor((delay - hours * 3600) / 60)
  local rv = AddTimer(name, hours, minutes, delay - hours * 3600 - minutes * 60, "",
    timer_flag.Enabled + timer_flag.OneShot + timer_flag.Temporary,
    "inv.runtime.fire")
  if rv ~= 0 then rt.timers[name] = nil; error("Cannot schedule dinv timer: " .. tostring(rv)) end
  return name
end

function inv.runtime.removeTimer(name)
  if name then
    inv.runtime.timers[name] = nil
    DeleteTimer(name)
  end
end

function inv.runtime.fire(name)
  local rt = inv.runtime
  local timer = rt.timers[name]
  rt.timers[name] = nil
  if not timer or timer.generation ~= rt.generation then return end
  local ok, err = pcall(timer.fn)
  if not ok then
    dbot.warn("Scheduled operation failed: " .. tostring(err))
    inv.runtime.cancelAll(DRL_RET_INTERNAL_ERROR)
    inv.runtime.scheduleBackground()
  end
end

function inv.runtime.current()
  return inv.runtime.tasks[coroutine.running()]
end

function inv.runtime.finish(task, retval, err)
  if task.done then return end
  task.done = true
  inv.runtime.tasks[task.thread] = nil
  inv.runtime.removeTimer(task.timer)
  if task.waiting and task.waiting.waiter == task then task.waiting.waiter = nil end
  if inv.commands then inv.commands.releaseWorkflow(task, retval) end
  if retval ~= DRL_RET_SUCCESS and task.owner and task.owner[task.key] == task.package then
    task.owner[task.key] = nil
    if type(task.package) == "table" and task.package.endTag then
      inv.tags.stop(task.package.tagModule, task.package.endTag, retval)
    end
  end
  if task.cleanup then
    local ok, message = pcall(task.cleanup, retval)
    if not ok then dbot.warn("Operation cleanup failed: " .. tostring(message)) end
  end
  if err then
    dbot.warn("Operation failed: " .. tostring(err))
    if inv.commands then inv.commands.cancelOwner(task, DRL_RET_INTERNAL_ERROR) end
  end
end

function inv.runtime.resume(task, ...)
  if task.done or task.generation ~= inv.runtime.generation then return end
  task.timer = nil
  local ok, result = coroutine.resume(task.thread, ...)
  if not ok then
    inv.runtime.finish(task, DRL_RET_INTERNAL_ERROR, result)
    -- A workflow can own nested requests and several domain locks. Abort the
    -- whole generation on an exception instead of retaining half a workflow.
    inv.runtime.cancelAll(DRL_RET_INTERNAL_ERROR)
    inv.runtime.scheduleBackground()
  elseif coroutine.status(task.thread) == "dead" then
    inv.runtime.finish(task, result or DRL_RET_SUCCESS)
  end
end

-- owner/key transfers a workflow's admission lock to this task. It is released
-- on failure, explicit cancellation, disable, and disconnect. Successful
-- workflows retain their existing result-package contract with their callers.
function inv.runtime.start(fn, owner, key, cleanup)
  local rt = inv.runtime
  if rt.stopping or not rt.enabled then return false end
  local task = { thread = coroutine.create(fn), generation = rt.generation,
    owner = owner, key = key, package = owner and owner[key], cleanup = cleanup }
  rt.tasks[task.thread] = task
  rt.resume(task)
  return not task.done or coroutine.status(task.thread) == "dead"
end

function inv.runtime.sleep(seconds)
  local task = assert(inv.runtime.current(), "dinv sleep requires an owned task")
  task.timer = inv.runtime.after(seconds, function() inv.runtime.resume(task) end)
  return coroutine.yield()
end

function inv.runtime.resolve(result, retval)
  if not result or result.isDone then return end
  result.retval = retval
  result.isDone = true
  local task = result.waiter
  result.waiter = nil
  if task and not task.done then
    inv.runtime.removeTimer(task.timer)
    task.waiting = nil
    -- Resume after the current trigger finishes; a resumed workflow must not
    -- replace a one-shot trigger while the host is still dispatching it.
    task.timer = inv.runtime.after(0, function() inv.runtime.resume(task, retval) end)
  end
end

function inv.runtime.await(result, timeout)
  if result.isDone then return result.retval end
  local task = assert(inv.runtime.current(), "dinv await requires an owned task")
  assert(not result.waiter, "A result already has a waiter")
  result.waiter, task.waiting = task, result
  if result.operation then
    inv.commands.setDeadline(result.operation, timeout)
  else
    task.timer = inv.runtime.after(timeout, function()
      inv.runtime.resolve(result, DRL_RET_TIMEOUT)
    end)
  end
  return coroutine.yield()
end

function inv.runtime.cancelAll(retval)
  local rt = inv.runtime
  if rt.stopping then return end
  rt.stopping = true
  retval = retval or DRL_RET_HALTED
  -- Stop continuations before delivering operation cancellations. Nothing may
  -- issue a follow-up command from an old task during teardown.
  local tasks = {}
  for _, task in pairs(rt.tasks) do tasks[#tasks + 1] = task end
  for _, task in ipairs(tasks) do rt.finish(task, retval) end
  if inv.commands then inv.commands.cancelAll(retval) end
  for name in pairs(rt.timers) do rt.removeTimer(name) end
  rt.generation = rt.generation + 1
  rt.stopping = false
  if inv.items then
    inv.items.abortCapture()
    inv.items.refreshPkg = nil
    inv.items.currentItems = nil
    inv.items.fullScanCompleted = false
    inv.items.mainState, inv.items.wornState, inv.items.keyringState =
      invItemsRefreshDirty, invItemsRefreshDirty, invItemsRefreshDirty
  end
  dbot.wish.inProgress = false
  inv.statBonus.bonusInProgress = false
  inv.portal.busyUntil = 0
  if inv.init.initializedActive and inv.state ~= invStatePaused then inv.state = invStateIdle end
end

function inv.runtime.scheduleBackground()
  if not inv.runtime.enabled or not inv.init.initializedActive then return end
  local minutes = inv.items.refreshGetPeriods() or 0
  if minutes > 0 then inv.items.refreshAtTime(minutes, 0) end
  inv.statBonus.timer.update(inv.statBonus.timer.min, inv.statBonus.timer.sec)
  inv.runtime.removeTimer(dbot.wish.timer.name)
  dbot.wish.timer.name = inv.runtime.after(dbot.wish.timer.min * 60 + dbot.wish.timer.sec, dbot.wish.get)
end

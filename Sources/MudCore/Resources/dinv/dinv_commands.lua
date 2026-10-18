-- One owner for game requests. Deadlines cover queueing AND execution. A
-- canceled request completes once, releases its parser, and drains its output
-- before another request can acquire the parser. User commands are never queued.
inv.commands = { queue = {}, active = nil, needsBoundary = false, outbound = {}, retired = {} }

-- Reserve the queue across a complete equipment workflow, including the gaps
-- between its requests. Acquisition is FIFO and does not send a game command.
-- Lua 5.1 cannot yield through pcall: runtime.finish owns exceptional cleanup.
function inv.commands.exclusive(fn, cleanup, timeout)
  local task = assert(inv.runtime.current(), "Equipment workflow requires an owned task")
  assert(inv.commands.leaseOwner ~= task, "Nested equipment workflow")
  local result = {}
  local retval = inv.commands.enqueue({}, nil, nil, nil, result, {acquire = true})
  if retval == DRL_RET_SUCCESS then retval = inv.runtime.await(result, 30) end
  if retval ~= DRL_RET_SUCCESS then return retval end
  task.workflowCleanup = cleanup
  task.workflowDeadline = inv.runtime.now() + (timeout or 90)
  retval = fn()
  inv.commands.releaseWorkflow(task, retval)
  return retval
end

function inv.commands.releaseWorkflow(task, retval)
  if inv.commands.leaseOwner ~= task then return end
  local cleanup = task.workflowCleanup
  task.workflowCleanup, task.workflowDeadline = nil, nil
  inv.commands.leaseOwner = nil
  if cleanup then
    local ok, err = pcall(cleanup, retval)
    if not ok then dbot.warn("Equipment cleanup: " .. tostring(err)) end
  end
  if not inv.runtime.stopping then inv.runtime.after(0, inv.commands.pump) end
end

-- Keep only the exact outstanding echo gag after releasing a canceled request.
-- These tombstones own no callbacks or timers; even a very late echo is harmless.
function inv.commands.retireMarker(name)
  local retired = inv.commands.retired
  retired[#retired + 1] = name
  if #retired > 64 then DeleteTrigger(table.remove(retired, 1)) end
end

function inv.commands.send(command)
  return SendNoEcho(dbot.execute.bypassPrefix .. command)
end

function inv.commands.armMarker(op, phase)
  op.phase = phase
  op.marker = "{ DINV fence " .. GetUniqueNumber() .. " }"
  op.trigger = "dinv_fence_" .. GetUniqueNumber()
  check(AddTriggerEx(op.trigger, "^" .. op.marker .. "$",
    "inv.commands.marker(\"" .. op.trigger .. "\")",
    drlTriggerFlagsBaseline + trigger_flag.OneShot + trigger_flag.OmitFromOutput,
    custom_colour.NoChange, 0, "", "", sendto.script, 0))
  inv.commands.send("echo " .. op.marker)
end

function inv.commands.deliver(op, retval)
  if op.done then return end
  op.done = true
  inv.runtime.removeTimer(op.timer)
  -- Parser cleanup must happen before notifying a caller or resuming a task.
  if op.cleanup then
    local ok, result = pcall(op.cleanup, op, retval)
    if not ok then retval = DRL_RET_INTERNAL_ERROR; dbot.warn("Request cleanup: " .. tostring(result))
    elseif type(result) == "number" then retval = result end
  end
  if op.resultFn then
    local ok, err = pcall(op.resultFn, op.resultData, retval)
    if not ok then retval = DRL_RET_INTERNAL_ERROR; dbot.warn("Request result: " .. tostring(err)) end
  end
  if type(op.resultData) == "table" then inv.runtime.resolve(op.resultData, retval) end
end

function inv.commands.release(op)
  if op.trigger then inv.commands.retireMarker(op.trigger); op.trigger = nil end
  inv.runtime.removeTimer(op.drainTimer)
  if inv.commands.active == op then inv.commands.active = nil end
  if not inv.runtime.stopping then
    inv.runtime.after(0, inv.commands.pump)
  end
end

function inv.commands.complete(op, retval)
  if inv.commands.active ~= op or op.done then return end
  inv.commands.deliver(op, retval)
  inv.commands.release(op)
end

function inv.commands.cancel(op, retval)
  if not op or op.done then return end
  local active = inv.commands.active == op
  inv.commands.deliver(op, retval or DRL_RET_HALTED)
  if active then
    -- A local cancellation cannot retract bytes already sent to the server.
    -- Retain only the unique closing marker, with all data capture disabled.
    inv.commands.needsBoundary = true
    if op.phase == "suffix" then
      op.phase = "draining"
      op.drainTimer = inv.runtime.after(10, function() inv.commands.release(op) end)
    else
      inv.commands.release(op)
    end
  end
end

function inv.commands.setDeadline(op, timeout)
  if op.done then return end
  local deadline = op.created + math.max(0.01, tonumber(timeout) or 30)
  if op.owner and op.owner.workflowDeadline then
    deadline = math.min(deadline, op.owner.workflowDeadline)
  end
  op.deadline = math.min(op.deadline or deadline, deadline)
  inv.runtime.removeTimer(op.timer)
  op.timer = inv.runtime.after(math.max(0.01, op.deadline - inv.runtime.now()), function()
    inv.commands.cancel(op, DRL_RET_TIMEOUT)
  end)
end

function inv.commands.enqueue(commands, setupFn, setupData, resultFn, resultData, options)
  if inv.runtime.stopping or not inv.runtime.enabled or not inv.init.initializedActive then
    return DRL_RET_UNINITIALIZED
  end
  options = options or {}
  local copy = {}
  for i, command in ipairs(commands) do copy[i] = command end
  local op = { commands = copy, setupFn = setupFn, setupData = setupData,
    resultFn = resultFn, resultData = resultData, cleanup = options.cleanup,
    framed = options.framed, identification = options.identification,
    capturesOutput = setupFn ~= nil, beforeDispatch = options.beforeDispatch,
    conflicts = options.conflicts, captureComplete = options.captureComplete, acquire = options.acquire,
    label = options.label or copy[1] or "synchronize",
    owner = inv.runtime.current(), created = inv.runtime.now() }
  if type(resultData) == "table" then resultData.operation = op end
  inv.commands.queue[#inv.commands.queue + 1] = op
  inv.commands.setDeadline(op, options.timeout or 30)
  -- Dispatch on the next client turn, giving the caller time to attach its
  -- deadline and transfer parser ownership before any response can arrive.
  inv.runtime.after(0, inv.commands.pump)
  return DRL_RET_SUCCESS, op
end

function inv.commands.dispatch(op)
  if inv.commands.waitForState(op) then return end
  local state = dbot.gmcp.getState()
  if inv.commands.inputPending() or (state ~= dbot.stateActive and state ~= dbot.stateCombat) then
    inv.commands.cancel(op, DRL_RET_NOT_ACTIVE)
    return
  end
  -- Input sent after the opening echo belongs before identification. Wait for
  -- a new boundary, including input received between that echo and this turn.
  if op.identification and op.refreshPrefix then
    op.refreshPrefix = nil
    inv.commands.armMarker(op, "prefix")
    return
  end
  if op.beforeDispatch then
    local ok, retval = pcall(op.beforeDispatch, op)
    if not ok then dbot.warn("Request precondition: " .. tostring(retval)) end
    if not ok or type(retval) ~= "number" then retval = DRL_RET_INTERNAL_ERROR end
    if retval ~= DRL_RET_SUCCESS then
      inv.commands.cancel(op, retval)
      return
    end
  end
  if op.setupFn then
    op.setupStarted = true
    local ok, err = pcall(op.setupFn, op.setupData)
    if not ok then
      dbot.warn("Request setup: " .. tostring(err))
      inv.commands.cancel(op, DRL_RET_INTERNAL_ERROR)
      return
    end
  end
  op.phase = "response"
  for _, command in ipairs(op.commands) do inv.commands.send(command) end
  if not op.framed then inv.commands.armMarker(op, "suffix") end
end

function inv.commands.pump()
  local queue = inv.commands
  if queue.active or inv.runtime.stopping then return end
  local op
  for index, candidate in ipairs(queue.queue) do
    if not candidate.done and (not queue.leaseOwner or candidate.owner == queue.leaseOwner) then
      op = table.remove(queue.queue, index)
      break
    end
  end
  for index = #queue.queue, 1, -1 do
    if queue.queue[index].done then table.remove(queue.queue, index) end
  end
  if not op then return end
  queue.active = op
  if op.acquire then
    queue.leaseOwner = op.owner
    queue.complete(op, DRL_RET_SUCCESS)
    return
  end
  queue.begin(op)
end

function inv.commands.waitForState(op)
  if op.owner and op.owner == inv.commands.leaseOwner and dbot.gmcp.getState() == dbot.stateRunning and
     not inv.commands.inputPending() then
    op.phase = "waitingState"
    return true
  end
  return false
end

function inv.commands.begin(op)
  if inv.commands.waitForState(op) then return end
  local queue = inv.commands
  local state = dbot.gmcp.getState()
  if inv.commands.inputPending() or (state ~= dbot.stateActive and state ~= dbot.stateCombat) then
    queue.cancel(op, DRL_RET_NOT_ACTIVE)
  elseif queue.needsBoundary or not op.framed then
    -- Unstructured legacy reports require an opening boundary. Structured
    -- inventory snapshots finish on their own matching closing tag.
    queue.armMarker(op, "prefix")
  else
    queue.dispatch(op)
  end
end

function inv.commands.stateChanged()
  local op = inv.commands.active
  if not op or op.done then return end
  local state = dbot.gmcp.getState()
  if state == dbot.stateActive or state == dbot.stateCombat then
    if op.phase == "waitingState" then inv.commands.begin(op) end
  elseif op.owner and op.owner == inv.commands.leaseOwner and state == dbot.stateRunning then
    -- An opening echo may still be in flight. Let it finish, then wait at
    -- dispatch; a command burst already on the wire must retain its completion.
    return
  elseif op.setupStarted and op.captureComplete and op.captureComplete() then
    return
  else
    inv.commands.cancel(op, DRL_RET_NOT_ACTIVE)
  end
end

function inv.commands.inputPending()
  -- The user's AFK/note command can be on the wire before GMCP changes state.
  return dbot.execute.afkIsPending or dbot.execute.noteIsPending
end

function inv.commands.backgroundReady()
  return dbot.gmcp.getState() == dbot.stateActive and not inv.commands.inputPending() and
    not inv.commands.active and not inv.commands.leaseOwner and #inv.commands.queue == 0
end

function inv.commands.probeNote(retval, message)
  if retval == DRL_RET_BUSY or retval == DRL_RET_NOT_ACTIVE or retval == DRL_RET_HALTED then
    dbot.debug(message)
  else dbot.note(message) end
end

function inv.commands.ownsResponse(result)
  return not result or not result.operation or result.operation.setupStarted
end

function inv.commands.marker(name)
  for index, retired in ipairs(inv.commands.retired) do
    if retired == name then table.remove(inv.commands.retired, index); return end
  end
  local op = inv.commands.active
  if not op or op.trigger ~= name then return end
  op.trigger = nil
  if op.phase == "prefix" and not op.done then
    inv.commands.needsBoundary = false
    -- Do not install a successor trigger inside this one's dispatch.
    inv.runtime.after(0, function()
      if inv.commands.active == op and not op.done then inv.commands.dispatch(op) end
    end)
  elseif op.phase == "draining" then
    inv.commands.needsBoundary = false
    inv.commands.release(op)
  elseif op.phase == "suffix" then
    inv.commands.complete(op, DRL_RET_SUCCESS)
  end
end

function inv.commands.cancelOwner(owner, retval)
  for _, op in ipairs(inv.commands.queue) do
    if op.owner == owner then inv.commands.cancel(op, retval) end
  end
  if inv.commands.active and inv.commands.active.owner == owner then
    inv.commands.cancel(inv.commands.active, retval)
  end
end

function inv.commands.cancelAll(retval)
  for _, op in ipairs(inv.commands.queue) do inv.commands.deliver(op, retval) end
  inv.commands.queue = {}
  local op = inv.commands.active
  if op then
    inv.commands.deliver(op, retval)
    inv.commands.needsBoundary = true
    inv.commands.release(op)
  end
end

function inv.commands.userInput(command)
  local verb = command:lower():match("^%s*(%S+)") or ""
  local rawSnapshot = verb == "invdata" or verb == "eqdata" or verb == "keyring"
  if rawSnapshot then inv.commands.needsBoundary = true end
  local op = inv.commands.active
  if not op or op.done then return end
  if op.identification then
    -- After dispatch, later commands follow the already-sent closing fence.
    -- Before dispatch, move the opening boundary past the intervening input.
    if not op.setupStarted then op.refreshPrefix = true end
    return
  end
  -- Only reports capture unrelated text. Pure command bursts need a unique
  -- acknowledgement, so ordinary output cannot corrupt them. Framed inventory
  -- reports only conflict with raw requests, which have no protocol request ID.
  local conflicts = op.framed and rawSnapshot or (not op.framed and op.capturesOutput)
  if op.conflicts then
    conflicts = false
    for expected in pairs(op.conflicts) do
      if verb ~= "" and expected:sub(1, #verb) == verb then conflicts = true end
    end
  end
  if op.setupStarted and op.captureComplete and op.captureComplete() then conflicts = false end
  if conflicts then inv.commands.cancel(op, DRL_RET_BUSY) end
end

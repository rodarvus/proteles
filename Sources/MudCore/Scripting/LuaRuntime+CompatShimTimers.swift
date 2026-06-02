import Foundation

/// The second half of the MUSHclient compat shim's Lua source — programmatic
/// timers (`AddTimer`/`DeleteTimer`, cancellable via liveness+generation),
/// deferred actions (`DoAfterSpecial`/`DoAfter`), `ReloadPlugin`, and the
/// remaining no-op API surface. Concatenated onto ``shimSourceCore`` to form one
/// Lua chunk; split into its own file only to stay within the file-length
/// budget (see ``automationShimSource``).
extension LuaRuntime {
    nonisolated static let shimSourceTimersAndPlugins = #"""
    -- Timer liveness + generation, kept in _G so the deferred fire-guard — which
    -- runs in the plugin env and resolves globals via the env's __index → _G —
    -- can read them. `DeleteTimer` clears liveness and `AddTimer`-with-Replace
    -- bumps the generation, so a cancelled or superseded one-shot becomes a
    -- no-op when it finally fires. (A common plugin pattern arms a "safety
    -- timeout" timer, then `DeleteTimer`s it on success; before this, the stale
    -- one-shot still fired — e.g. resetting a capture gate every ~10s.)
    __protelesTimerLive = __protelesTimerLive or {}
    __protelesTimerGen = __protelesTimerGen or {}
    -- The per-timer fire spec (interval seconds + the exact body string) for
    -- recurring timers, so __protelesReschedule can re-arm with the identical
    -- body. Keyed by timer name; a re-arm (Replace) or DeleteTimer overwrites/
    -- clears it.
    __protelesTimerSpec = __protelesTimerSpec or {}
    -- Names of timers armed with timer_flag.Temporary, so DeleteTemporaryTimers
    -- can bulk-clear exactly those (MUSHclient parity).
    __timerTemporary = __timerTemporary or {}
    -- Re-arm a recurring timer one interval after it fires. Runs in _G (the host
    -- only needs to re-schedule, not touch the plugin env), but is *called from*
    -- the fire body, which runs in the plugin env. It re-checks liveness +
    -- generation so a DeleteTimer'd or superseded (Replace) timer stops the
    -- chain, then defers the SAME body again — the body itself contains this
    -- re-arm call, so the chain self-perpetuates until cancelled.
    function __protelesReschedule(key, gen)
      if not (__protelesTimerLive[key] and __protelesTimerGen[key] == gen) then return end
      local spec = __protelesTimerSpec[key]
      if spec and spec.gen == gen then proteles.doAfter(spec.seconds, spec.body, true) end
    end
    -- Programmatic timers/triggers → host effects. AddTimer defers a call to its
    -- script, guarded by liveness+generation so DeleteTimer can cancel it and a
    -- re-armed (Replace) timer supersedes the old fire. A recurring (non-OneShot,
    -- the MUSHclient default) timer's body also calls __protelesReschedule, so it
    -- re-fires every interval — matching MUSHclient — until DeleteTimer clears its
    -- liveness or a re-arm bumps its generation. A one-shot (timer_flag.OneShot)
    -- fires exactly once.
    -- Arm (or re-arm) a timer's deferred fire for its CURRENT generation, from
    -- the spec AddTimer recorded. A recurring timer's body re-arms via
    -- __protelesReschedule; a one-shot's doesn't. Shared by AddTimer and by
    -- SetTimerOption re-enabling a paused timer, so both build an identical body.
    function __protelesArmTimer(key)
      local s = __protelesTimerSpec[key]
      if not (s and s.script and s.script ~= "") then return end
      local gen = __protelesTimerGen[key]
      local fire = string.format(
        "if __protelesTimerLive[%q] and __protelesTimerGen[%q] == %d then %s(%q)",
        key, key, gen, s.script, key)
      if s.recurring then fire = fire .. string.format(" __protelesReschedule(%q, %d)", key, gen) end
      fire = fire .. " end"
      s.body = fire; s.gen = gen
      proteles.doAfter(s.seconds, fire, true)
    end
    function AddTimer(name, hour, minute, second, response, flags, script)
      local seconds = (tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60
        + (tonumber(second) or 0)
      local key = tostring(name)
      local f = tonumber(flags) or 0
      __timerNames[key] = true
      __protelesTimerLive[key] = true
      __protelesTimerGen[key] = (__protelesTimerGen[key] or 0) + 1
      -- Bit 2 (value 4 = timer_flag.OneShot) — Lua 5.1 has no bitops, so isolate
      -- it arithmetically; the lower flags (Enabled=1, AtTime=2) can't reach it.
      local oneShot = (math.floor(f / timer_flag.OneShot) % 2) >= 1
      -- timer_flag.Temporary (16384, bit 14): DeleteTemporaryTimers bulk-clears these.
      __timerTemporary[key] = ((math.floor(f / timer_flag.Temporary) % 2) >= 1) or nil
      if script and script ~= "" then
        -- A recurring timer with a non-positive interval would hot-loop the host;
        -- treat it as a one-shot (MUSHclient clamps such intervals anyway).
        __protelesTimerSpec[key] = {
          seconds = seconds, script = script, recurring = (not oneShot) and seconds > 0,
        }
        __protelesArmTimer(key)
      end
      return error_code.eOK
    end
    -- Deferred actions → one-shot timers on the host's timer engine. With
    -- sendto.script (12) / sendto.scriptafteromit (14) the text runs as Lua in
    -- the owning plugin's env; otherwise it's sent to the MUD. dinv's reload,
    -- execute-queue re-arm, and version paths all rely on DoAfterSpecial.
    function DoAfterSpecial(seconds, text, sendtoValue)
      -- sendto.execute (10): the deferred text is processed like typed input —
      -- aliases, speedwalk AND command stacking (`;`). dinv relies on this for
      -- its portal sequence, e.g. `wear <id> portal;put <id> <bag>`: the client
      -- must split on `;` into two commands. We defer a script that calls
      -- `Execute`, which routes through the host command pipeline (where the
      -- `;` split happens) — a raw send would hand Aardwolf the whole stacked
      -- string and it'd treat `portal;put …` as the wear location.
      if sendtoValue == 10 then
        proteles.doAfter(tonumber(seconds) or 0,
                         "Execute(" .. string.format("%q", tostring(text)) .. ")", true)
        return error_code.eOK
      end
      local isScript = (sendtoValue == 12 or sendtoValue == 14)
      proteles.doAfter(tonumber(seconds) or 0, tostring(text), isScript)
      return error_code.eOK
    end
    function DoAfter(seconds, text)
      proteles.doAfter(tonumber(seconds) or 0, tostring(text), false)
      return error_code.eOK
    end
    -- ReloadPlugin: tear down and re-instantiate a plugin by id. A plugin can
    -- ask the host to reload itself (dinv's `dinv reload`); the host routes by
    -- kind (native / bundled dinv / on-disk MUSHclient).
    function ReloadPlugin(id) proteles.reloadPlugin(tostring(id)); return error_code.eOK end
    -- Build the Lua a trigger runs when it fires, matching MUSHclient: a non-
    -- empty `script` is a handler called as `fn(name, line, wildcards)`; else,
    -- with a script send-to (12/14, the AddTriggerEx default in the Aardwolf
    -- corpus), the `response` text is run as Lua (the host %-expands %1/%0/… to
    -- captures first); else the response is sent to the world. An empty body is
    -- a no-op (e.g. an OmitFromOutput-only suppression trigger).
    local function __triggerBody(name, response, script, sendtoVal)
      if script and script ~= "" then
        return script .. "(" .. string.format("%q", tostring(name)) .. ", matches[0], matches)"
      end
      response = tostring(response or "")
      if response == "" then return "" end
      if sendtoVal == nil or sendtoVal == 12 or sendtoVal == 14 then return response end
      return "Send(" .. string.format("%q", response) .. ")"
    end
    -- Per-trigger spec, so SetTriggerOption can rebuild a named trigger with a
    -- changed match/sequence (the host's addTrigger replaces a same-named
    -- trigger). `enabled` is tracked apart from `flags` because EnableTrigger /
    -- SetTriggerOption("enabled") toggle engine state without rewriting flags; a
    -- later rebuild must preserve that live enabled/disabled state. The temporary
    -- bit (trigger_flag.Temporary) feeds DeleteTemporaryTriggers.
    __triggerSpec = __triggerSpec or {}
    __triggerTemporary = __triggerTemporary or {}
    -- trigger_flag.Enabled is bit 0 (value 1); set/clear it arithmetically.
    local function __withEnabled(flags, enabled)
      local hasBit = (flags % 2) == 1
      if enabled and not hasBit then return flags + 1 end
      if (not enabled) and hasBit then return flags - 1 end
      return flags
    end
    local function __registerTriggerSpec(key, match, flags, body, seq)
      __triggerSpec[key] = { match = match, flags = flags, body = body, seq = seq,
                             enabled = (flags % 2) == 1 }
      __triggerTemporary[key] = ((math.floor(flags / trigger_flag.Temporary) % 2) >= 1) or nil
    end
    -- Re-create a named trigger from its spec with the live enabled state folded
    -- back into the flags (the host's addTrigger replaces the same-named one).
    local function __rebuildTrigger(key)
      local s = __triggerSpec[key]
      if not s then return end
      proteles.addTrigger(key, s.match, __withEnabled(s.flags, s.enabled), s.body, s.seq)
    end
    function AddTriggerEx(name, match, response, flags, colour, wildcard, sound, script, sendto, seq)
      local key, m, f = tostring(name), tostring(match), tonumber(flags) or 0
      local body, s = __triggerBody(name, response, script, sendto), tonumber(seq) or 100
      proteles.addTrigger(key, m, f, body, s)
      __triggerNames[key] = true
      __registerTriggerSpec(key, m, f, body, s)
      return error_code.eOK
    end
    function AddTrigger(name, match, response, flags, colour, wildcard, sound, script)
      -- AddTrigger has no send_to param; MUSHclient defaults to the world.
      local key, m, f = tostring(name), tostring(match), tonumber(flags) or 0
      local body = __triggerBody(name, response, script, 1)
      proteles.addTrigger(key, m, f, body)
      __triggerNames[key] = true
      __registerTriggerSpec(key, m, f, body, 100)
      return error_code.eOK
    end
    function DeleteTrigger(name)
      local key = tostring(name)
      proteles.removeTrigger(key); __triggerNames[key] = nil
      __triggerSpec[key] = nil; __triggerTemporary[key] = nil
      return error_code.eOK
    end
    -- AddAlias/EnableAlias: register/toggle a runtime alias on the host's alias
    -- engine (owner-scoped, like AddTriggerEx). `script` is the handler name.
    function AddAlias(name, match, response, flags, script)
      proteles.addAlias(tostring(name), tostring(match), tonumber(flags) or 0, script or "")
      __aliasNames[tostring(name)] = true
      return error_code.eOK
    end
    function EnableAlias(name, flag)
      proteles.enableAlias(tostring(name), not (flag == false or flag == nil or flag == 0))
      return error_code.eOK
    end
    function DeleteTimer(name)
      local key = tostring(name)
      __timerNames[key] = nil
      __protelesTimerLive[key] = nil -- cancel pending fire (it self-skips); stops recurrence
      __protelesTimerSpec[key] = nil
      __timerTemporary[key] = nil
      return error_code.eOK
    end
    -- Existence checks (MUSHclient world API): eOK when the named object exists,
    -- else the type-specific not-found code. dinv's de-init wrappers branch on
    -- these to skip deleting objects that were never instantiated.
    function IsTrigger(name)
      return __triggerNames[tostring(name)] and error_code.eOK or error_code.eTriggerNotFound
    end
    function IsTimer(name)
      return __timerNames[tostring(name)] and error_code.eOK or error_code.eTimerNotFound
    end
    function IsAlias(name)
      return __aliasNames[tostring(name)] and error_code.eOK or error_code.eAliasNotFound
    end
    -- SetTriggerOption: honour the options that map to host operations —
    -- `enabled` (engine toggle), `group` (move to a named group), and
    -- `sequence`/`match` (rebuild the named trigger, since the host's addTrigger
    -- replaces by name). The live enabled state is remembered so a rebuild
    -- preserves it. Other options (omit_from_output, ignore_case, …) aren't
    -- applied yet but still return eOK (a plugin setting them won't error).
    function SetTriggerOption(name, option, value)
      local key = tostring(name)
      if option == "enabled" then
        -- Falsy across the forms MUSHclient passes: boolean, number 0, string "0"/"false".
        local on = not (value == false or value == nil or value == 0 or value == "0" or value == "false")
        proteles.enableTrigger(key, on)
        if __triggerSpec[key] then __triggerSpec[key].enabled = on end
      elseif option == "group" then
        proteles.setTriggerGroup(key, tostring(value))
      elseif option == "sequence" and __triggerSpec[key] then
        __triggerSpec[key].seq = tonumber(value) or __triggerSpec[key].seq
        __rebuildTrigger(key)
      elseif option == "match" and __triggerSpec[key] then
        __triggerSpec[key].match = tostring(value)
        __rebuildTrigger(key)
      end
      return error_code.eOK
    end
    -- SetTimerOption: honour `enabled`. Shim timers are doAfter chains (not
    -- TimerEngine entries), so disable PAUSES by clearing liveness (the pending
    -- fire/reschedule self-skips); enable bumps the generation (so any stale
    -- pending fire dies) and re-arms from the spec. Other options return eOK.
    function SetTimerOption(name, option, value)
      local key = tostring(name)
      if option == "enabled" then
        local on = not (value == false or value == nil or value == 0 or value == "0" or value == "false")
        if on then
          if not __protelesTimerLive[key] and __protelesTimerSpec[key] then
            __protelesTimerLive[key] = true
            __protelesTimerGen[key] = (__protelesTimerGen[key] or 0) + 1
            __protelesArmTimer(key)
          end
        else
          __protelesTimerLive[key] = false
        end
      end
      return error_code.eOK
    end
    -- Bulk-clear temporary automation (MUSHclient parity): remove exactly the
    -- triggers/timers armed with the Temporary flag, returning the count.
    function DeleteTemporaryTriggers()
      local n = 0
      for key in pairs(__triggerTemporary) do
        proteles.removeTrigger(key)
        __triggerNames[key] = nil; __triggerSpec[key] = nil
        n = n + 1
      end
      __triggerTemporary = {}
      return n
    end
    function DeleteTemporaryTimers()
      local n = 0
      for key in pairs(__timerTemporary) do
        __timerNames[key] = nil; __protelesTimerLive[key] = nil; __protelesTimerSpec[key] = nil
        n = n + 1
      end
      __timerTemporary = {}
      return n
    end
    """#
}

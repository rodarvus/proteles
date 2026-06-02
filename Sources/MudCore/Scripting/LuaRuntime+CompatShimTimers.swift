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
    function AddTimer(name, hour, minute, second, response, flags, script)
      local seconds = (tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60
        + (tonumber(second) or 0)
      local key = tostring(name)
      __timerNames[key] = true
      __protelesTimerLive[key] = true
      __protelesTimerGen[key] = (__protelesTimerGen[key] or 0) + 1
      local gen = __protelesTimerGen[key]
      -- Bit 2 (value 4 = timer_flag.OneShot) — Lua 5.1 has no bitops, so isolate
      -- it arithmetically; the lower flags (Enabled=1, AtTime=2) can't reach it.
      local oneShot = (math.floor((tonumber(flags) or 0) / timer_flag.OneShot) % 2) >= 1
      -- A recurring timer with a non-positive interval would hot-loop the host;
      -- treat it as a one-shot (MUSHclient clamps such intervals anyway).
      local recurring = (not oneShot) and seconds > 0
      if script and script ~= "" then
        local fire = string.format(
          "if __protelesTimerLive[%q] and __protelesTimerGen[%q] == %d then %s(%q)",
          key, key, gen, script, key)
        if recurring then
          fire = fire .. string.format(" __protelesReschedule(%q, %d)", key, gen)
        end
        fire = fire .. " end"
        __protelesTimerSpec[key] = { seconds = seconds, body = fire, gen = gen }
        proteles.doAfter(seconds, fire, true)
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
    function AddTriggerEx(name, match, response, flags, colour, wildcard, sound, script, sendto, seq)
      proteles.addTrigger(tostring(name), tostring(match), tonumber(flags) or 0,
                          __triggerBody(name, response, script, sendto), tonumber(seq) or 100)
      __triggerNames[tostring(name)] = true
      return error_code.eOK
    end
    function AddTrigger(name, match, response, flags, colour, wildcard, sound, script)
      -- AddTrigger has no send_to param; MUSHclient defaults to the world.
      proteles.addTrigger(tostring(name), tostring(match), tonumber(flags) or 0,
                          __triggerBody(name, response, script, 1))
      __triggerNames[tostring(name)] = true
      return error_code.eOK
    end
    function DeleteTrigger(name)
      proteles.removeTrigger(tostring(name)); __triggerNames[tostring(name)] = nil
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
    function SetTimerOption(name, option, value) return error_code.eOK end
    function SetTriggerOption(name, option, value) return error_code.eOK end
    function DeleteTemporaryTriggers() return 0 end
    function DeleteTemporaryTimers() return 0 end
    """#
}

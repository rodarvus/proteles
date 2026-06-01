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
    -- Programmatic timers/triggers → host effects. AddTimer becomes a one-shot
    -- deferred call to its script, guarded by liveness+generation so DeleteTimer
    -- can cancel it and a re-armed (Replace) timer supersedes the old fire.
    -- Recurring (non-OneShot) timers still fire only once (a known limitation).
    function AddTimer(name, hour, minute, second, response, flags, script)
      local seconds = (tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60
        + (tonumber(second) or 0)
      local key = tostring(name)
      __timerNames[key] = true
      __protelesTimerLive[key] = true
      __protelesTimerGen[key] = (__protelesTimerGen[key] or 0) + 1
      if script and script ~= "" then
        proteles.doAfter(seconds,
          string.format(
            "if __protelesTimerLive[%q] and __protelesTimerGen[%q] == %d then %s(%q) end",
            key, key, __protelesTimerGen[key], script, key),
          true)
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
      __protelesTimerLive[key] = nil -- cancel any pending one-shot (it self-skips)
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

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
    -- The plugin id that armed each shim timer. These tables are shared across
    -- ALL plugins (the shim loads once into the real globals), so any bulk op
    -- (ResetTimers) MUST scope to the calling plugin's own timers — otherwise
    -- re-arming runs `proteles.doAfter` in the *caller's* env and steals another
    -- plugin's timer into it (e.g. dinv's wish timer firing where `dbot` is nil).
    __protelesTimerOwner = __protelesTimerOwner or {}
    -- Absolute (monotonic) fire deadline per shim timer, so GetTimerInfo can
    -- answer infotype 13 ("seconds to go") — plugins drive countdown displays off
    -- it (e.g. Aard_Affects' affect timers). Set on every (re-)arm.
    __protelesTimerDeadline = __protelesTimerDeadline or {}
    -- Group each shim timer belongs to (set via SetTimerOption("group",…)), so
    -- DeleteTimerGroup can clear the caller's own timers in a group.
    __protelesTimerGroup = __protelesTimerGroup or {}
    -- Full teardown of a shim timer's tracking (shared by DeleteTimer and the
    -- one-shot fire body — a one-shot must stop "existing" once it fires, like
    -- MUSHclient, so the common `if IsTimer(x) ~= eOK then AddTimer(...)` re-arm
    -- idiom works; without this IsTimer stayed eOK forever and broke it).
    function __protelesClearTimer(key)
      __timerNames[key] = nil; __protelesTimerLive[key] = nil; __protelesTimerSpec[key] = nil
      __timerTemporary[key] = nil; __protelesTimerOwner[key] = nil; __protelesTimerDeadline[key] = nil
      __protelesTimerGroup[key] = nil
    end
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
      if s.recurring then
        fire = fire .. string.format(" __protelesReschedule(%q, %d)", key, gen)
      else
        -- A one-shot tears itself down after firing (MUSHclient deletes one-shot
        -- timers on fire), so IsTimer reports it gone and re-arm idioms work.
        fire = fire .. string.format(" __protelesClearTimer(%q)", key)
      end
      fire = fire .. " end"
      s.body = fire; s.gen = gen
      __protelesTimerDeadline[key] = proteles.monotonic() + (s.seconds or 0)
      proteles.doAfter(s.seconds, fire, true)
    end
    function AddTimer(name, hour, minute, second, response, flags, script)
      local seconds = (tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60
        + (tonumber(second) or 0)
      local key = tostring(name)
      local f = tonumber(flags) or 0
      __timerNames[key] = true
      __protelesTimerOwner[key] = GetPluginID() -- scope ResetTimers to this plugin
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
    -- Names of triggers armed with trigger_flag.Temporary (bit 14), so
    -- DeleteTemporaryTriggers can bulk-clear exactly those (MUSHclient parity).
    __triggerTemporary = __triggerTemporary or {}
    -- Which plugin added each trigger — the tracking tables are shared across all
    -- plugins, so DeleteTemporaryTriggers must scope to the caller's own (a bulk
    -- wipe would delete other plugins' temporary triggers). Same rationale as
    -- __protelesTimerOwner.
    __triggerOwner = __triggerOwner or {}
    -- Group each trigger/alias belongs to (set via Set*Option("group",…) /
    -- addxml / ImportXML), so DeleteTriggerGroup/DeleteAliasGroup can clear the
    -- caller's own members of a group. __aliasOwner mirrors __triggerOwner.
    __triggerGroup = __triggerGroup or {}
    __aliasGroup = __aliasGroup or {}
    __aliasOwner = __aliasOwner or {}
    local function __trackTriggerTemporary(key, flags)
      __triggerTemporary[key] = ((math.floor(flags / trigger_flag.Temporary) % 2) >= 1) or nil
      __triggerOwner[key] = GetPluginID()
    end
    function AddTriggerEx(name, match, response, flags, colour, wildcard, sound, script, sendto, seq)
      local key, f = tostring(name), tonumber(flags) or 0
      proteles.addTrigger(key, tostring(match), f,
                          __triggerBody(name, response, script, sendto), tonumber(seq) or 100)
      __triggerNames[key] = true
      __trackTriggerTemporary(key, f)
      return error_code.eOK
    end
    function AddTrigger(name, match, response, flags, colour, wildcard, sound, script)
      -- AddTrigger has no send_to param; MUSHclient defaults to the world.
      local key, f = tostring(name), tonumber(flags) or 0
      proteles.addTrigger(key, tostring(match), f, __triggerBody(name, response, script, 1))
      __triggerNames[key] = true
      __trackTriggerTemporary(key, f)
      return error_code.eOK
    end
    function DeleteTrigger(name)
      local key = tostring(name)
      proteles.removeTrigger(key); __triggerNames[key] = nil
      __triggerTemporary[key] = nil
      __triggerOwner[key] = nil
      __triggerGroup[key] = nil
      return error_code.eOK
    end
    -- DeleteAlias: the alias counterpart to DeleteTrigger (many plugins clear
    -- their temp aliases in a `for … DeleteAlias(list[i])` loop on disable).
    function DeleteAlias(name)
      local key = tostring(name)
      proteles.removeAlias(key); __aliasNames[key] = nil
      __aliasGroup[key] = nil
      __aliasOwner[key] = nil
      return error_code.eOK
    end
    -- AddAlias/EnableAlias: register/toggle a runtime alias on the host's alias
    -- engine (owner-scoped, like AddTriggerEx). `script` is the handler name.
    function AddAlias(name, match, response, flags, script)
      local key = tostring(name)
      proteles.addAlias(key, tostring(match), tonumber(flags) or 0, script or "")
      __aliasNames[key] = true
      __aliasOwner[key] = GetPluginID()
      return error_code.eOK
    end
    function EnableAlias(name, flag)
      proteles.enableAlias(tostring(name), not (flag == false or flag == nil or flag == 0))
      return error_code.eOK
    end
    function DeleteTimer(name)
      -- Clearing liveness cancels the pending fire (it self-skips); the rest is
      -- the shared teardown. (Mirrors what a one-shot does to itself on fire.)
      __protelesClearTimer(tostring(name))
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
    -- SetTriggerOption: `enabled` and `group` route to their own engine ops
    -- (both resolve a trigger by name, XML- or shim-registered). Everything else
    -- — omit_from_output, keep_evaluating, ignore_case, sequence, match — goes to
    -- proteles.setTriggerOption, which mutates the named trigger on the engine in
    -- place (so it works for XML-plugin triggers too, e.g. Galaban's exit plugin
    -- toggling omit_from_output). An option the host doesn't model is ignored
    -- there; the call still returns eOK so a plugin setting it won't error.
    function SetTriggerOption(name, option, value)
      local key = tostring(name)
      if option == "enabled" then
        -- Falsy across the forms MUSHclient passes: boolean, number 0, string "0"/"false".
        local on = not (value == false or value == nil or value == 0 or value == "0" or value == "false")
        proteles.enableTrigger(key, on)
      elseif option == "group" then
        __triggerGroup[key] = tostring(value) -- for DeleteTriggerGroup
        proteles.setTriggerGroup(key, tostring(value))
      else
        proteles.setTriggerOption(key, tostring(option), tostring(value))
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
      elseif option == "group" then
        __protelesTimerGroup[key] = tostring(value) -- for DeleteTimerGroup
      end
      return error_code.eOK
    end
    -- Bulk-clear temporary automation (MUSHclient parity): remove exactly the
    -- triggers/timers armed with the Temporary flag — but ONLY the CALLING
    -- plugin's own (the tracking tables are shared across all plugins, so a blind
    -- wipe would delete another plugin's temporary objects). Returns the count.
    function DeleteTemporaryTriggers()
      local me, n = GetPluginID(), 0
      for key in pairs(__triggerTemporary) do
        if __triggerOwner[key] == me then
          proteles.removeTrigger(key)
          __triggerNames[key] = nil
          __triggerTemporary[key] = nil
          __triggerOwner[key] = nil
          __triggerGroup[key] = nil
          n = n + 1
        end
      end
      return n
    end
    function DeleteTemporaryTimers()
      local me, n = GetPluginID(), 0
      for key in pairs(__timerTemporary) do
        if __protelesTimerOwner[key] == me then
          __protelesClearTimer(key)
          n = n + 1
        end
      end
      return n
    end
    -- Group delete (MUSHclient DeleteTriggerGroup/DeleteAliasGroup/
    -- DeleteTimerGroup): remove every trigger/alias/timer in the named group that
    -- THIS plugin owns (the tracking tables are shared across plugins), via the
    -- per-name delete (which cleans both the host engine and the shim shadow).
    -- Returns the count. The delete-group-then-rebuild idiom relies on this.
    function DeleteTriggerGroup(group)
      local me, g, n = GetPluginID(), tostring(group), 0
      -- collect first (DeleteTrigger mutates __triggerGroup mid-iteration)
      local names = {}
      for key, grp in pairs(__triggerGroup) do
        if grp == g and __triggerOwner[key] == me then names[#names + 1] = key end
      end
      for _, key in ipairs(names) do DeleteTrigger(key); n = n + 1 end
      return n
    end
    function DeleteAliasGroup(group)
      local me, g, n = GetPluginID(), tostring(group), 0
      local names = {}
      for key, grp in pairs(__aliasGroup) do
        if grp == g and __aliasOwner[key] == me then names[#names + 1] = key end
      end
      for _, key in ipairs(names) do DeleteAlias(key); n = n + 1 end
      return n
    end
    function DeleteTimerGroup(group)
      local me, g, n = GetPluginID(), tostring(group), 0
      local names = {}
      for key, grp in pairs(__protelesTimerGroup) do
        if grp == g and __protelesTimerOwner[key] == me then names[#names + 1] = key end
      end
      for _, key in ipairs(names) do __protelesClearTimer(key); n = n + 1 end
      return n
    end
    -- Trigger/alias introspection (MUSHclient GetTriggerInfo/GetAliasInfo +
    -- the Get*List family) — broadly used by plugins to render and reflect on
    -- their own automation (print a trigger table, read back a pattern/enabled
    -- state). Triggers and aliases — XML-declared and AddTriggerEx/AddAlias
    -- alike — live on the host engines, so these read straight from the host's
    -- snapshot mirror. The `InfoType` numbers are MUSHclient's exactly. A
    -- missing name/field yields nil (MUSHclient VT_EMPTY); an empty list yields
    -- nil (the Get*List functions can't return an empty array).
    function GetTriggerInfo(name, infotype)
      return proteles.triggerInfo(tostring(name), tonumber(infotype) or 0)
    end
    function GetAliasInfo(name, infotype)
      return proteles.aliasInfo(tostring(name), tonumber(infotype) or 0)
    end
    function GetTriggerList() return proteles.triggerList() end
    function GetAliasList() return proteles.aliasList() end
    function GetPluginTriggerList(id) return proteles.pluginTriggerList(tostring(id or "")) end
    -- Option-name getters (MUSHclient GetTriggerOption/GetAliasOption): the same
    -- fields as Get*Info, addressed by the option name from the *OptionsTable
    -- rather than a numeric infotype. An unmodelled option returns nil (VT_EMPTY).
    function GetTriggerOption(name, option)
      return proteles.triggerOption(tostring(name), tostring(option))
    end
    function GetAliasOption(name, option)
      return proteles.aliasOption(tostring(name), tostring(option))
    end
    -- GetPluginTriggerInfo(id, name, infotype): GetTriggerInfo scoped to a
    -- trigger owned by another plugin (used by inspection commands listing a
    -- companion plugin's triggers).
    function GetPluginTriggerInfo(id, name, infotype)
      return proteles.pluginTriggerInfo(tostring(id or ""), tostring(name), tonumber(infotype) or 0)
    end
    -- StopEvaluatingTriggers([all]): halt the rest of this line's trigger
    -- evaluation from inside a fired trigger's script (the send_to=script idiom
    -- the map/bigmap plugins use). The optional arg (stop *all* plugins too) is
    -- carried for fidelity but doesn't change behaviour in our single engine.
    function StopEvaluatingTriggers(all)
      proteles.stopEvaluatingTriggers(all == true)
    end
    -- Timer introspection. Shim timers (AddTimer) are doAfter chains tracked in
    -- the __protelesTimer* tables, not host TimerEngine entries, so consult
    -- those first; fall back to the host snapshot for XML/engine timers. The
    -- field numbers match MUSHclient's GetTimerInfo.
    function GetTimerInfo(name, infotype)
      local key, t = tostring(name), tonumber(infotype) or 0
      local spec = __protelesTimerSpec[key]
      if spec then
        local s = spec.seconds or 0
        if t == 1 then return math.floor(s / 3600) end
        if t == 2 then return math.floor((s % 3600) / 60) end
        if t == 3 then return s - math.floor(s / 60) * 60 end
        if t == 5 then return spec.script or "" end
        if t == 6 then return __protelesTimerLive[key] and true or false end
        if t == 7 then return not spec.recurring end
        if t == 8 then return false end                       -- not an at-time timer
        -- 13 = seconds remaining until the timer fires (countdown displays use it).
        if t == 13 then return math.max(0, (__protelesTimerDeadline[key] or 0) - proteles.monotonic()) end
        if t == 14 then return __timerTemporary[key] and true or false end
        return nil
      end
      return proteles.timerInfo(key, t)
    end
    function GetTimerList()
      local names, seen = {}, {}
      for key in pairs(__timerNames) do names[#names + 1] = key; seen[key] = true end
      local engine = proteles.timerList()
      if engine then
        for _, key in ipairs(engine) do
          if not seen[key] then names[#names + 1] = key; seen[key] = true end
        end
      end
      if #names == 0 then return nil end
      return names
    end
    -- GetTimerOption(name, option): like GetTimerInfo but keyed by option name.
    -- Shim timers (doAfter chains) answer from the __protelesTimer* tables first
    -- (same as GetTimerInfo); engine/XML timers fall back to the host snapshot.
    function GetTimerOption(name, option)
      local key, opt = tostring(name), tostring(option)
      local spec = __protelesTimerSpec[key]
      if spec then
        local s = spec.seconds or 0
        if opt == "hour" then return math.floor(s / 3600) end
        if opt == "minute" then return math.floor((s % 3600) / 60) end
        if opt == "second" then return s - math.floor(s / 60) * 60 end
        if opt == "script" then return spec.script or "" end
        if opt == "enabled" then return __protelesTimerLive[key] and true or false end
        if opt == "one_shot" then return not spec.recurring end
        if opt == "at_time" then return false end
        if opt == "temporary" then return __timerTemporary[key] and true or false end
        return nil
      end
      return proteles.timerOption(key, opt)
    end
    -- SetAliasOption(name, option, value): the alias-side SetTriggerOption.
    -- `enabled` routes to EnableAlias; everything else (group, match, sequence,
    -- ignore_case, keep_evaluating) mutates the alias on the engine. Always eOK.
    function SetAliasOption(name, option, value)
      local key = tostring(name)
      if option == "enabled" then
        local on = not (value == false or value == nil or value == 0 or value == "0" or value == "false")
        proteles.enableAlias(key, on)
      else
        if option == "group" then __aliasGroup[key] = tostring(value) end -- for DeleteAliasGroup
        proteles.setAliasOption(key, tostring(option), tostring(value))
      end
      return error_code.eOK
    end
    -- ResetTimer: re-arm a timer's countdown from now. A shim timer re-arms its
    -- doAfter chain (bump the generation so any pending fire self-skips, then
    -- re-arm from its spec); an engine timer routes to the host. Returns eOK.
    function ResetTimer(name)
      local key = tostring(name)
      -- Only re-arm a shim timer the CALLING plugin owns — re-arming runs
      -- proteles.doAfter in the caller's env, so resetting another plugin's timer
      -- would steal it into the wrong env. Non-owned/engine timers route to host.
      if __protelesTimerSpec[key] and __protelesTimerOwner[key] == GetPluginID() then
        __protelesTimerLive[key] = true
        __protelesTimerGen[key] = (__protelesTimerGen[key] or 0) + 1
        __protelesArmTimer(key)
        return error_code.eOK
      end
      proteles.resetTimer(key)
      return error_code.eOK
    end
    -- ImportXML(xml): install triggers/aliases/timers from an XML fragment, as
    -- MUSHclient's world.ImportXML does. Plugins that build trigger/alias XML in
    -- a loop and import it (rather than calling AddTriggerEx directly) rely on
    -- this; without it they error in OnPluginInstall ("attempt to call global
    -- 'ImportXML'"). We parse the fragment and dispatch to the existing
    -- AddTriggerEx/AddAlias/AddTimer shim globals, returning the count installed
    -- (-1 if the argument isn't a string), matching the reference's return.
    -- LIMITATION: per-trigger highlight colours (other_text_colour /
    -- other_back_colour / custom_colour) are parsed off but NOT applied — the
    -- trigger registers and fires, it just doesn't recolour the matched line
    -- (our engine highlights foreground-only and runtime-added triggers don't
    -- yet carry a highlight). Tracked separately.
    local function __xmlUnescape(v)
      v = string.gsub(v, "&lt;", "<")
      v = string.gsub(v, "&gt;", ">")
      v = string.gsub(v, "&quot;", '"')
      v = string.gsub(v, "&apos;", "'")
      v = string.gsub(v, "&amp;", "&")
      return v
    end
    local function __xmlAttrs(blob)
      local a = {}
      for k, v in string.gmatch(blob, '([%w_]+)%s*=%s*"(.-)"') do a[k] = __xmlUnescape(v) end
      return a
    end
    local function __xmlTruthy(v) return v == "y" or v == "yes" or v == "1" or v == true end
    local function __xmlFalsy(v) return v == "n" or v == "no" or v == "0" or v == false end
    local __importSeq = 0
    local function __importName(a, prefix)
      if a.name and a.name ~= "" then return a.name end
      __importSeq = __importSeq + 1
      return prefix .. "_importxml_" .. __importSeq
    end
    function ImportXML(xml)
      if type(xml) ~= "string" then return -1 end
      local count = 0
      for blob in string.gmatch(xml, "<trigger%s(.-)>") do
        local a = __xmlAttrs(blob)
        local f = (__xmlFalsy(a.enabled) and 0) or trigger_flag.Enabled
        if __xmlTruthy(a.regexp) or __xmlTruthy(a.regular_expression) then
          f = f + trigger_flag.RegularExpression
        end
        if __xmlTruthy(a.ignore_case) then f = f + trigger_flag.IgnoreCase end
        if __xmlTruthy(a.keep_evaluating) then f = f + trigger_flag.KeepEvaluating end
        if __xmlTruthy(a.omit_from_output) then f = f + trigger_flag.OmitFromOutput end
        if __xmlTruthy(a.omit_from_log) then f = f + trigger_flag.OmitFromLog end
        if __xmlTruthy(a.expand_variables) then f = f + trigger_flag.ExpandVariables end
        if __xmlTruthy(a.temporary) then f = f + trigger_flag.Temporary end
        if __xmlTruthy(a.one_shot) then f = f + trigger_flag.OneShot end
        local name = __importName(a, "trigger")
        AddTriggerEx(name, a.match or "", a.send or "", f, custom_colour.NoChange, "", "",
          a.script or "", tonumber(a.send_to) or sendto.world, tonumber(a.sequence) or 100)
        if a.group and a.group ~= "" then SetTriggerOption(name, "group", a.group) end
        count = count + 1
      end
      for blob in string.gmatch(xml, "<alias%s(.-)>") do
        local a = __xmlAttrs(blob)
        local f = (__xmlFalsy(a.enabled) and 0) or alias_flag.Enabled
        if __xmlTruthy(a.regexp) or __xmlTruthy(a.regular_expression) then
          f = f + alias_flag.RegularExpression
        end
        if __xmlTruthy(a.ignore_case) then f = f + alias_flag.IgnoreCase end
        if __xmlTruthy(a.omit_from_output) then f = f + alias_flag.OmitFromOutput end
        if __xmlTruthy(a.temporary) then f = f + alias_flag.Temporary end
        if __xmlTruthy(a.one_shot) then f = f + alias_flag.OneShot end
        local name = __importName(a, "alias")
        AddAlias(name, a.match or "", a.send or "", f, a.script or "")
        if a.group and a.group ~= "" then SetAliasOption(name, "group", a.group) end
        count = count + 1
      end
      for blob in string.gmatch(xml, "<timer%s(.-)>") do
        local a = __xmlAttrs(blob)
        local f = (__xmlFalsy(a.enabled) and 0) or timer_flag.Enabled
        if __xmlTruthy(a.one_shot) then f = f + timer_flag.OneShot end
        if __xmlTruthy(a.temporary) then f = f + timer_flag.Temporary end
        AddTimer(__importName(a, "timer"), tonumber(a.hour) or 0, tonumber(a.minute) or 0,
          tonumber(a.second) or 0, a.send or "", f, a.script or "")
        count = count + 1
      end
      return count
    end
    -- Info bar (status strip): MUSHclient's one-line strip below the output. The
    -- reference no-ops these when no info bar exists (methods_infobar.cpp); we
    -- have none, so stub them so plugins driving one (quest/status trackers)
    -- install + run without erroring. Their info-bar output simply isn't shown.
    function ShowInfoBar(show) return error_code.eOK end
    function Info(text) return error_code.eOK end
    function InfoClear() return error_code.eOK end
    function InfoColour(name) return error_code.eOK end
    function InfoBackground(name) return error_code.eOK end
    function InfoFont(name, size, style) return error_code.eOK end
    -- NoteStyle(style): sets bold/underline/etc. for subsequent Note output in
    -- MUSHclient. We don't carry per-note style state generically, so accept +
    -- ignore (a no-op) so style-setting plugins run; the text still prints.
    function NoteStyle(style) return error_code.eOK end
    -- OpenBrowser(url): open a URL in the user's browser. MUSHclient hands the
    -- string straight to ShellExecute; here we (1) restrict to web schemes
    -- (http/https/mailto) so a plugin can't launch arbitrary handlers, and (2)
    -- hand the app the calling plugin's id+name so it can gate the open behind a
    -- per-plugin confirmation. Returns eBadParameter for an unsupported scheme.
    function OpenBrowser(url)
      url = tostring(url)
      if not (url:match("^[hH][tT][tT][pP][sS]?://") or url:match("^[mM][aA][iI][lL][tT][oO]:")) then
        return error_code.eBadParameter
      end
      proteles.openBrowser(url, GetPluginID(), GetPluginInfo(GetPluginID(), 1) or "")
      return error_code.eOK
    end
    -- ResetTimers(): re-arm the CALLING plugin's shim timers (the plural form
    -- some plugins call). Scoped by owner — the spec tables are shared across all
    -- plugins, so resetting every entry would steal other plugins' timers into
    -- this plugin's env. ResetTimer's own owner-guard makes this doubly safe.
    function ResetTimers()
      local me = GetPluginID()
      for key in pairs(__protelesTimerSpec) do
        if __protelesTimerOwner[key] == me then ResetTimer(key) end
      end
      return error_code.eOK
    end
    """#
}

import Foundation

/// Programmatic automation for the shared runtime: the MUSHclient world API
/// (`AddTimer`/`AddTriggerEx`/`EnableTrigger`/`DeleteTrigger`/…) that plugins —
/// and helper libraries like `wait` — use to register triggers/timers at run
/// time. The compat shim records these as ``ScriptEffect`` values; here we
/// apply them to the engine's own ``TriggerEngine``/``TimerEngine``, owned by
/// the calling plugin so the callbacks run in its environment.
///
/// Mirrors ``SearchAndDestroyHost``'s machinery, which proved the pattern.
extension ScriptEngine {
    /// MUSHclient `AddTrigger` flag bits (submodules/mushclient/flags.h).
    enum TriggerFlag {
        static let enabled = 0x01
        static let omitFromOutput = 0x04
        static let ignoreCase = 0x10
        static let regularExpression = 0x20
        static let temporary = 0x4000
        static let oneShot = 0x8000
    }

    /// MUSHclient `AddAlias` flag bits (submodules/mushclient/flags.h — note these differ
    /// from the trigger bits: `eIgnoreAliasCase = 0x20`,
    /// `eAliasRegularExpression = 0x80`).
    enum AliasFlag {
        static let enabled = 0x01
        static let ignoreCase = 0x20
        static let regularExpression = 0x80
        static let temporary = 0x4000
    }

    /// Apply the programmatic-automation effects a script produced to our own
    /// engines, returning the remaining outward effects (sends/echoes/notes)
    /// for the session to render.
    func consumeRegistrations(_ effects: [ScriptEffect], owner: String?) -> [ScriptEffect] {
        effects.filter { !applyAutomationEffect($0, owner: owner) }
    }

    /// Apply one programmatic-automation effect to the engines. Returns `true`
    /// if consumed, `false` if it's an outward effect the session should render.
    private func applyAutomationEffect(_ effect: ScriptEffect, owner: String?) -> Bool {
        switch effect {
        case .addTrigger(let name, let pattern, let flags, let script, let sequence):
            addDynamicTrigger(
                .init(name: name, pattern: pattern, flags: flags, script: script, sequence: sequence),
                owner: owner
            )
        case .addAlias(let name, let pattern, let flags, let script):
            addDynamicAlias(name: name, pattern: pattern, flags: flags, script: script, owner: owner)
        case .scheduleAfter(let seconds, let isScript, let body):
            scheduleOneShot(after: seconds, isScript: isScript, body: body, owner: owner)
        case .setTriggerGroup(let name, let group):
            setDynamicTriggerGroup(name: name, group: group)
        case .setTriggerOption(let name, let option, let value):
            setTriggerOptionByName(name: name, option: option, value: value)
        case .removeTrigger(let name):
            if let id = triggerIDsByName.removeValue(forKey: name) {
                triggers.remove(id: id)
                automationOwners[id] = nil
            }
        case .enableTrigger, .enableTimer, .enableAlias, .enableGroup:
            applyEnableEffect(effect)
        default:
            return false
        }
        return true
    }

    /// Apply a name-based enable/disable to the matching engine.
    private func applyEnableEffect(_ effect: ScriptEffect) {
        switch effect {
        case .enableTrigger(let name, let on):
            if let id = triggerIDsByName[name] { triggers.setEnabled(on, id: id) }
        case .enableTimer(let name, let on):
            if let id = timerIDsByName[name] { timers.setEnabled(on, id: id) }
        case .enableAlias(let name, let on):
            if let id = aliasIDsByName[name] { aliases.setEnabled(on, id: id) }
        case .enableGroup(let name, let on):
            triggers.setGroupEnabled(on, group: name)
            timers.setGroupEnabled(on, group: name)
        default:
            break
        }
    }

    /// Invoke `name` on every loaded plugin's environment, in load order,
    /// consuming each plugin's registrations owner-scoped: a broadcast callback
    /// may AddTimer/AddTriggerEx (dinv's init coroutine yields on wait.time → a
    /// resume timer); returning them raw drops it and the coroutine hangs.
    func fireCallbackOnAll(_ name: String, _ arguments: [LuaValue] = []) async -> [ScriptEffect] {
        var effects: [ScriptEffect] = []
        for pluginID in loadedPluginIDs {
            let raw = await runtime.callPluginCallback(pluginID, name, arguments)
            effects.append(contentsOf: consumeRegistrations(raw, owner: pluginID))
        }
        return effects
    }

    /// Fire `OnPluginConnect` on a **single** plugin (for a mid-session enable
    /// while already in-game — the rest of the world keeps running untouched).
    public func connectPlugin(_ id: String) async -> [ScriptEffect] {
        await consumeRegistrations(runtime.callPluginCallback(id, "OnPluginConnect"), owner: id)
    }

    /// Deliver an inbound GMCP message to every plugin's
    /// `OnPluginTelnetSubnegotiation(201, "<package> <json>")` — MUSHclient fires
    /// this for the raw GMCP subnegotiation (telnet option 201). dinv's config
    /// detection reads ONLY this path (`dbot.gmcp.currentState[mode]` is set
    /// there), so without it every `getConfig` (prompt/invmon/…) times out at 5s
    /// and dinv falls back to defaults. The body keeps Aardwolf's exact spacing
    /// (`{ "prompt" : "YES" }`), which dinv's pattern requires.
    public func deliverGMCPSubnegotiation(package: String, json: String) async -> [ScriptEffect] {
        await fireCallbackOnAll("OnPluginTelnetSubnegotiation", [
            .number(201),
            .string("\(package) \(json)")
        ])
    }

    /// Run an arbitrary chunk in an already-loaded plugin's environment,
    /// returning the effects it recorded. Used to install dinv's init-chain
    /// debug instrumentation after load (the chunk just installs wrappers and
    /// returns — it does not yield, so the surrounding `pcall` is safe).
    public func runInPluginEnvironment(_ pluginID: String, _ source: String) async -> [ScriptEffect] {
        await runtime.loadPluginScript(source, pluginID: pluginID)
    }

    /// Tear down a single loaded MUSHclient plugin so it can be reloaded
    /// cleanly (MUSHclient `ReloadPlugin`). Removes the triggers/aliases/timers
    /// it owns (and their name lookups), drops its Lua environment — which
    /// releases its globals and lifecycle callbacks so they can't fire again —
    /// and forgets it from the load order. Idempotent: unloading an unknown id
    /// is a no-op. State that lives outside the engine (scoped variables, the
    /// plugin's own SQLite DB) is intentionally preserved across the reload.
    public func unloadPlugin(_ id: String) async {
        let ownedIDs = Set(automationOwners.filter { $0.value == id }.keys)
        for ownedID in ownedIDs {
            triggers.remove(id: ownedID)
            aliases.remove(id: ownedID)
            timers.remove(id: ownedID)
            automationOwners[ownedID] = nil
        }
        triggerIDsByName = triggerIDsByName.filter { !ownedIDs.contains($0.value) }
        aliasIDsByName = aliasIDsByName.filter { !ownedIDs.contains($0.value) }
        timerIDsByName = timerIDsByName.filter { !ownedIDs.contains($0.value) }
        loadedPluginIDs.removeAll { $0 == id }
        await runtime.clearPluginEnvironment(id)
    }

    /// True when `id` names a registered native (Swift) plugin (so the host can
    /// route a reload to disable→enable rather than the unload/reload path).
    public func isNativePlugin(id: String) -> Bool {
        nativePlugins.listing.contains { $0.metadata.id == id }
    }

    /// Whether a one-shot was scheduled since the last check (read + cleared by
    /// the session so it re-arms its timer loop exactly once).
    public func takeDidScheduleTimer() -> Bool {
        defer { didScheduleTimer = false }
        return didScheduleTimer
    }

    // MARK: - Private

    /// The decoded inputs of an `AddTrigger`/`AddTriggerEx` call, grouped so the
    /// registration helper stays within the parameter budget.
    private struct DynamicTriggerSpec {
        let name: String
        let pattern: String
        let flags: Int
        let script: String
        /// MUSHclient evaluation order (lower fires first; default 100).
        let sequence: Int
    }

    /// Register an `AddTrigger`/`AddTriggerEx` trigger. The script name becomes
    /// the MUSHclient-style call `fn(name, matches[0], matches)` and runs in the
    /// owning plugin's environment. Honours the Enabled/IgnoreCase/Regex/Omit/
    /// OneShot flag bits.
    private func addDynamicTrigger(_ spec: DynamicTriggerSpec, owner: String?) {
        let isRegex = spec.flags & TriggerFlag.regularExpression != 0
        // The shim hands us the full Lua body (function-call, raw response, or
        // a world Send), so run it verbatim — the fire path %-expands it.
        let call = spec.script.isEmpty ? nil : spec.script
        let trigger = Trigger(
            name: spec.name,
            pattern: isRegex ? .regex(spec.pattern) : .wildcard(spec.pattern),
            caseSensitive: spec.flags & TriggerFlag.ignoreCase == 0,
            enabled: spec.flags & TriggerFlag.enabled != 0,
            // Honour the MUSHclient evaluation order: dinv assigns its
            // wish-capture trigger sequence 0 so it fires before any co-loaded
            // plugin's stop-on-match trigger that would otherwise pre-empt it on
            // the owned wish lines (the portal-when-worn bug). Default is 100.
            sequence: spec.sequence,
            oneShot: spec.flags & TriggerFlag.oneShot != 0,
            gag: spec.flags & TriggerFlag.omitFromOutput != 0,
            script: call
        )
        if let existing = triggerIDsByName[spec.name] { triggers.remove(id: existing) }
        guard (try? triggers.add(trigger)) != nil else { return }
        triggerIDsByName[spec.name] = trigger.id
        automationOwners[trigger.id] = owner
    }

    /// Register an `AddAlias` alias. Like ``addDynamicTrigger`` but on the alias
    /// engine: the script name becomes the MUSHclient call
    /// `fn(name, line, wildcards)` (`.script` target) and runs in the owning
    /// plugin's environment (e.g. dinv's regen `sleep` alias). Honours the
    /// Enabled/IgnoreCase/Regex flag bits.
    private func addDynamicAlias(
        name: String,
        pattern: String,
        flags: Int,
        script: String,
        owner: String?
    ) {
        let isRegex = flags & AliasFlag.regularExpression != 0
        let call = script.isEmpty ? nil
            : "\(script)(\(Self.luaString(name)), matches[0], matches)"
        let alias = Alias(
            name: name,
            pattern: isRegex ? .regex(pattern) : .wildcard(pattern),
            caseSensitive: flags & AliasFlag.ignoreCase == 0,
            enabled: flags & AliasFlag.enabled != 0,
            sendText: call,
            sendTo: call == nil ? .world : .script
        )
        if let existing = aliasIDsByName[name] { aliases.remove(id: existing) }
        guard (try? aliases.add(alias)) != nil else { return }
        aliasIDsByName[name] = alias.id
        automationOwners[alias.id] = owner
    }

    /// Schedule a one-shot deferred action (`DoAfter`/`DoAfterSpecial`/the
    /// one-shot timers `wait` builds). Runs in the owning plugin's environment.
    private func scheduleOneShot(after seconds: Double, isScript: Bool, body: String, owner: String?) {
        let timer = MudTimer(
            schedule: .after(max(0, seconds)),
            action: isScript ? .script(body) : .send(body),
            temporary: true
        )
        guard (try? timers.add(timer)) != nil else { return }
        automationOwners[timer.id] = owner
        didScheduleTimer = true
    }

    /// Move a runtime trigger into a group (so `EnableTriggerGroup` toggles it).
    private func setDynamicTriggerGroup(name: String, group: String) {
        guard let id = triggerIDsByName[name],
              var trigger = triggers.allTriggers.first(where: { $0.id == id })
        else { return }
        trigger.group = group
        triggers.remove(id: id)
        guard (try? triggers.add(trigger)) != nil else { return }
        triggerIDsByName[name] = trigger.id
    }

    /// Apply a `SetTriggerOption` option to a named trigger by mutating it in
    /// place on the engine (remove + re-add with the same id), so it works for
    /// XML-plugin-defined triggers — e.g. Galaban's exit plugin toggling
    /// `omit_from_output` at runtime — not just shim-registered ones. `enabled`
    /// and `group` are handled by their own effects; this covers the rest.
    /// Unrecognised options are left untouched (the call still returns eOK).
    private func setTriggerOptionByName(name: String, option: String, value: String) {
        guard let id = triggerIDsByName[name],
              var trigger = triggers.allTriggers.first(where: { $0.id == id })
        else { return }
        switch option {
        case "omit_from_output": trigger.gag = Self.mushTruthy(value)
        case "keep_evaluating": trigger.continueEvaluation = Self.mushTruthy(value)
        case "ignore_case": trigger.caseSensitive = !Self.mushTruthy(value)
        case "enabled": trigger.enabled = Self.mushTruthy(value)
        case "sequence":
            guard let sequence = Int(value) else { return }
            trigger.sequence = sequence
        case "match": trigger.pattern = Self.repattern(trigger.pattern, value)
        default: return // an option we don't model — leave the trigger unchanged
        }
        triggers.remove(id: id)
        guard (try? triggers.add(trigger)) != nil else { return }
        triggerIDsByName[name] = trigger.id
    }

    /// MUSHclient option booleans: truthy unless empty / 0 / n[o] / false / off.
    private static func mushTruthy(_ value: String) -> Bool {
        let normalised = value.trimmingCharacters(in: .whitespaces).lowercased()
        return !(["", "0", "n", "no", "false", "off"].contains(normalised))
    }

    /// Rebuild a trigger pattern with new text, preserving its match kind.
    private static func repattern(_ current: TriggerPattern, _ text: String) -> TriggerPattern {
        switch current {
        case .substring: .substring(text)
        case .beginsWith: .beginsWith(text)
        case .exact: .exact(text)
        case .wildcard: .wildcard(text)
        case .regex: .regex(text)
        }
    }

    /// A Lua string literal (escaped) for embedding a name in a generated call.
    private static func luaString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

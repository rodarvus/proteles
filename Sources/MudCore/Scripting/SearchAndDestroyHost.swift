import Foundation

/// Runs the vendored Search-and-Destroy *logic* on a dedicated, sandboxed
/// ``LuaRuntime`` with a **curated** host binding — exactly the MUSHclient
/// functions S&D needs, backed by our `proteles.*` primitives (not the
/// generic `mush.lua` shim). The MUSHclient miniwindow (`Window*`/`Hyperlink`/
/// `movewindow`) is stubbed here and replaced by a native SwiftUI panel in
/// later stages; the search/campaign/gquest/DB logic is reused unchanged.
///
/// S1.2 scope: stand up the runtime, register S&D's modules, install the
/// bindings, and load `core.lua` (its functions become callable). Wiring the
/// triggers/aliases/timers + the data bridge + UI come in S1.3+.
public actor SearchAndDestroyHost {
    public enum HostError: Error, Equatable {
        case assetsMissing
        case loadFailed(String)
    }

    private let runtime: LuaRuntime
    /// The latest JSON model S&D published (via the `xg_draw_window` bridge).
    public private(set) var model: String?

    /// S&D's triggers/aliases/timers, parsed from the vendored plugin XML.
    /// These drive the host's own matching (S&D runs on its dedicated runtime,
    /// not the shared `ScriptEngine`), populated by ``load()``.
    public private(set) var automations: MUSHclientPlugin?

    // S&D's own automation engines (pure value types). S&D runs on a dedicated
    // runtime with curated bindings, so it can't share `ScriptEngine`'s engines
    // — the host drives matching itself and runs fired scripts on `runtime`.
    private var triggers = TriggerEngine()
    private var aliases = AliasEngine()
    private var timers = TimerEngine()
    /// Name → engine id, so S&D's `EnableTrigger`/`EnableTimer` (by name) can
    /// toggle the right rule.
    private var triggerIDsByName: [String: UUID] = [:]
    private var timerIDsByName: [String: UUID] = [:]
    private var aliasIDsByName: [String: UUID] = [:]
    /// Set when a `DoAfter`/`DoAfterSpecial` one-shot is scheduled, so the
    /// session knows to re-arm its timer loop. Cleared by ``takeDidScheduleTimer``.
    private var didScheduleTimer = false

    public init() throws {
        runtime = try LuaRuntime()
    }

    /// Point S&D at its data directory — `GetInfo(66)` (where it finds the
    /// mapper DB as `<WorldName>.db` and keeps its own `SnDdb.db`) and the
    /// lsqlite3 sandbox root. Call before ``load()`` (S&D captures the DB
    /// paths from `GetInfo(66)` at load time).
    public func configure(directory: String) async {
        let suffixed = directory.hasSuffix("/") ? directory : directory + "/"
        var context = PluginContext.default
        context.pluginID = Self.pluginID
        context.pluginName = "Search_and_Destroy"
        context.appDirectory = suffixed // GetInfo(66)
        context.worldDirectory = suffixed
        context.pluginDirectory = suffixed // GetInfo(60)
        await runtime.setPluginContext(context)
        await runtime.setSQLiteDirectory(directory)
    }

    /// S&D's well-known MUSHclient plugin id.
    public static let pluginID = "30000000537461726C696E67"

    /// Register S&D's modules + curated bindings and load its `core.lua`.
    /// Throws if the vendored script is missing or fails to compile/run.
    public func load() async throws {
        guard let core = SearchAndDestroyAssets.core else { throw HostError.assetsMissing }

        // S&D's `require`/`dofile` targets resolve from these modules (the
        // loader falls back to a module by basename for dofile): its own data
        // modules (downloaded with it) + Gammon's bundled wait/check.
        await runtime.registerModules(SearchAndDestroyAssets.helperModules) // constants, area data
        await runtime.registerModules(MUSHHelperAssets.modules) // wait, check (Gammon)
        await runtime.registerModules(LuaRuntime.standardHelpers.filter {
            ["serialize", "tprint", "json", "aardwolf_colors"].contains($0.key)
        })
        await runtime.registerModule("movewindow", source: Self.movewindowStub)

        // Curated host API (globals S&D calls), then the script itself. S&D's
        // `xg_draw_window` carries a small [Proteles bridge] block that
        // publishes its model (it must live in core.lua's scope to read the
        // display locals); we just capture the published JSON in `run`.
        do {
            _ = try await runtime.run(Self.bindings)
            _ = try await runtime.run(core)
            _ = try await runtime.run(Self.postLoadOverrides)
        } catch {
            throw HostError.loadFailed(String(describing: error))
        }

        try loadAutomations()
    }

    /// Neutralise S&D's network self-update path. `download_file` checks an
    /// `async` HTTP helper we don't provide and otherwise emits a visible
    /// "Error on file download" note on startup (via `check_for_updates`).
    /// Override it (and the update entry points) to quiet no-ops — Proteles
    /// vendors S&D; it isn't self-updating.
    private static let postLoadOverrides = """
    if type(download_file) == "function" then download_file = function() end end
    if type(check_for_updates) == "function" then check_for_updates = function() end end
    if type(force_update_check) == "function" then force_update_check = function() end end
    if type(download_sounds) == "function" then download_sounds = function() end end

    -- Auto-detect an already-running campaign. `setup_scan_con_triggers()` runs
    -- exactly once, when init finishes (`init_called == 2`), so wrapping it is a
    -- reliable "init complete" signal — and unlike `init_called`/
    -- `current_activity` (core.lua locals invisible to this chunk) it's a global
    -- we can hook. Two things on that signal:
    --   1. Persistently arm `trg_cp_info_targets`/`trg_cp_info_level_taken` (run
    --      here, in a consumed timer-fire path, so the enable reaches the host
    --      engine). Aardwolf auto-shows "YOUR CURRENT CAMPAIGN" on login, often
    --      *before* a requested `cp info` — without the entry trigger armed, that
    --      block scrolls by unparsed and the campaign is never detected. Armed,
    --      it fires the transient line/end triggers and the chain completes.
    --   2. Also request a `cp info` shortly after, for when nothing auto-shows.
    if type(setup_scan_con_triggers) == "function" and type(do_cp_info) == "function" then
      local __snd_orig_setup = setup_scan_con_triggers
      setup_scan_con_triggers = function(...)
        __snd_orig_setup(...)
        EnableTrigger("trg_cp_info_level_taken", true)
        EnableTrigger("trg_cp_info_targets", true)
        DoAfterSpecial(1.0, "do_cp_info()", sendto.script)
      end
    end
    """

    /// Force a campaign/quest detection pass — run S&D's `do_cp_info()` (sends
    /// `cp info`, enables the scrape triggers, and on the end-of-info line sets
    /// `current_activity = "cp"` + publishes). Used by the panel's "Scan now"
    /// and a best-effort auto-scan after connect, so an *already-running*
    /// campaign is detected without the player re-requesting it (S&D otherwise
    /// only auto-detects on the grant line or from cached area data).
    public func scanForActivity() async -> [ScriptEffect] {
        let effects = await (try? runtime.run(
            "if type(do_cp_info) == 'function' then do_cp_info() end"
        )) ?? []
        return consume(effects)
    }

    /// Parse S&D's triggers/aliases/timers from the vendored plugin XML into
    /// ``automations``. The XML carries PCRE regexes with `(?<name>…)` groups
    /// that aren't valid XML attribute content, so it's normalised first
    /// (``SearchAndDestroyXML``) before the shared ``MUSHclientPluginLoader``
    /// reads it. Idempotent; also runs as part of ``load()``.
    public func loadAutomations() throws {
        guard let xml = SearchAndDestroyAssets.pluginXML else { throw HostError.assetsMissing }
        let plugin: MUSHclientPlugin
        do {
            plugin = try MUSHclientPluginLoader.parse(xml: SearchAndDestroyXML.normalise(xml))
        } catch {
            throw HostError.loadFailed(String(describing: error))
        }
        automations = plugin
        seedEngines(from: plugin)
    }

    /// Load S&D's automations into the host's engines. Patterns that don't
    /// compile (a PCRE construct ICU rejects) are skipped, best-effort, so one
    /// odd trigger can't disable the whole plugin.
    private func seedEngines(from plugin: MUSHclientPlugin) {
        triggers = TriggerEngine()
        aliases = AliasEngine()
        timers = TimerEngine()
        triggerIDsByName.removeAll()
        timerIDsByName.removeAll()
        aliasIDsByName.removeAll()

        for trigger in plugin.triggers {
            guard (try? triggers.add(trigger)) != nil else { continue }
            if let name = trigger.name { triggerIDsByName[name] = trigger.id }
        }
        for alias in plugin.aliases {
            guard (try? aliases.add(alias)) != nil else { continue }
            if let name = alias.name { aliasIDsByName[name] = alias.id }
        }
        for timer in plugin.timers {
            guard let id = try? timers.add(timer) else { continue }
            if let name = timer.label { timerIDsByName[name] = id }
        }
    }

    // MARK: - Dispatch (the session drives these)

    /// Run an incoming MUD line through S&D's triggers, returning the outward
    /// effects (sends/echoes/published model) and whether any matched trigger
    /// gags the line (`omit_from_output` — S&D's cp info/check scrape triggers
    /// all set it, so its internal command output never reaches the window).
    /// Enable/disable effects S&D's Lua emitted are applied to the host's own
    /// engines, not returned.
    public func process(_ line: String) async -> (effects: [ScriptEffect], gag: Bool) {
        var out: [ScriptEffect] = []
        var gag = false
        for firing in triggers.process(line) {
            if firing.gag { gag = true }
            out += await applyFiring(send: firing.send, script: firing.script, match: firing.match)
        }
        return (out, gag)
    }

    /// Offer a typed command to S&D's aliases. Returns the resulting effects,
    /// or `nil` if no S&D alias matched (so the caller sends it normally).
    public func expandCommand(_ input: String) async -> [ScriptEffect]? {
        let firings = aliases.match(input)
        guard !firings.isEmpty else { return nil }
        var out: [ScriptEffect] = []
        for firing in firings {
            guard let send = firing.send else { continue }
            switch firing.target {
            case .script:
                await out += consume(runScript(send, match: firing.match))
            case .world: out.append(.send(send))
            case .execute: out.append(.execute(send))
            case .output: out.append(.echo(send))
            }
        }
        return out
    }

    /// The next instant any enabled S&D timer is due, or nil if none — so the
    /// session's timer loop can include S&D's deadlines.
    public func nextTimerDeadline() -> Date? {
        timers.nextDeadline()
    }

    /// Fire any of S&D's timers that are due at `now` (e.g. the one-shot
    /// `tim_init_plugin` bootstrap and the navigation tick timers).
    public func fireTimers(at now: Date = Date()) async -> [ScriptEffect] {
        var out: [ScriptEffect] = []
        for firing in timers.due(at: now) {
            out += await applyFiring(send: firing.send, script: firing.script, match: nil)
        }
        return out
    }

    /// S&D's GMCP-handler plugin id (`plugin_id_gmcp_handler` in core.lua).
    /// Its `gmcp(path)`/`send_gmcp_packet` route `CallPlugin` to this id; our
    /// curated bindings answer it from the runtime's live `proteles.gmcp`.
    public static let gmcpHandlerID = "3e7dedbe37e44942dd46d264"

    /// Update S&D's view of the connection (`IsConnected()` gates its
    /// init/bootstrap). Mirror the session's connection state here.
    public func setConnected(_ value: Bool) async {
        await runtime.setConnected(value)
    }

    /// Project a GMCP message into S&D's runtime (`proteles.gmcp`) and fire its
    /// `OnPluginBroadcast(1, <gmcp id>, "GMCP", package)` — the path by which
    /// S&D learns it's on a campaign/quest and tracks the current room.
    public func applyGMCP(package: String, json: String) async -> [ScriptEffect] {
        var effects = await runtime.applyGMCP(package: package, json: json)
        effects += await runtime.callGlobal("OnPluginBroadcast", [
            .number(1),
            .string(Self.gmcpHandlerID),
            .string("GMCP"),
            .string(package)
        ])
        return consume(effects)
    }

    private func applyFiring(send: String?, script: String?, match: TriggerMatch?) async -> [ScriptEffect] {
        var out: [ScriptEffect] = []
        if let send, !send.isEmpty { out.append(.send(send)) }
        if let script, !script.isEmpty {
            await out += consume(runScript(script, match: match))
        }
        return out
    }

    private func runScript(_ script: String, match: TriggerMatch?) async -> [ScriptEffect] {
        do {
            return try await runtime.runScript(
                script,
                matches: match?.captures ?? [],
                named: match?.named ?? [:]
            )
        } catch {
            return []
        }
    }

    /// Apply S&D's host-internal enable/disable effects to the host's engines
    /// and capture the latest published model; return the remaining outward
    /// effects (sends/echoes/publishModel) for the session to apply.
    private func consume(_ effects: [ScriptEffect]) -> [ScriptEffect] {
        var out: [ScriptEffect] = []
        for effect in effects {
            if case .publishModel(let json) = effect {
                model = json
                out.append(effect)
            } else if !applyHostInternalEffect(effect) {
                out.append(effect)
            }
        }
        return out
    }

    /// Apply a host-internal automation effect (enable/timer/dynamic-trigger)
    /// to the host's own engines. Returns `true` if it was consumed, `false`
    /// if it's an outward effect the session should apply.
    private func applyHostInternalEffect(_ effect: ScriptEffect) -> Bool {
        switch effect {
        case .enableTrigger, .enableTimer, .enableAlias, .enableGroup:
            applyEnableEffect(effect)
        case .scheduleAfter(let seconds, let isScript, let body):
            scheduleOneShot(after: seconds, isScript: isScript, body: body)
        case .addTrigger(let name, let pattern, let flags, let script):
            addDynamicTrigger(name: name, pattern: pattern, flags: flags, script: script)
        case .setTriggerGroup(let name, let group):
            setDynamicTriggerGroup(name: name, group: group)
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

    /// MUSHclient AddTrigger flag bits (mushclient/flags.h).
    private enum TriggerFlag {
        static let enabled = 0x01
        static let omitFromOutput = 0x04
        static let ignoreCase = 0x10
        static let regularExpression = 0x20
    }

    /// Register a trigger at runtime into the host's TriggerEngine (S&D's
    /// scan/consider matchers via `AddTriggerEx`). The script name becomes the
    /// MUSHclient-style call `fn(name, matches[0], matches)`.
    private func addDynamicTrigger(name: String, pattern: String, flags: Int, script: String) {
        let isRegex = flags & TriggerFlag.regularExpression != 0
        let call = script.isEmpty ? nil
            : "\(script)(\(Self.luaString(name)), matches[0], matches)"
        let trigger = Trigger(
            name: name,
            pattern: isRegex ? .regex(pattern) : .wildcard(pattern),
            caseSensitive: flags & TriggerFlag.ignoreCase == 0,
            enabled: flags & TriggerFlag.enabled != 0,
            gag: flags & TriggerFlag.omitFromOutput != 0,
            script: call
        )
        if let existing = triggerIDsByName[name] { triggers.remove(id: existing) }
        guard (try? triggers.add(trigger)) != nil else { return }
        triggerIDsByName[name] = trigger.id
    }

    /// Set a runtime trigger's group (so `EnableTriggerGroup` toggles it).
    private func setDynamicTriggerGroup(name: String, group: String) {
        guard let id = triggerIDsByName[name],
              var trigger = triggers.allTriggers.first(where: { $0.id == id })
        else { return }
        trigger.group = group
        triggers.remove(id: id)
        if (try? triggers.add(trigger)) != nil { triggerIDsByName[name] = trigger.id }
    }

    /// A Lua string literal (escaped) for embedding a trigger name in a call.
    private static func luaString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Add a one-shot timer (MUSHclient `DoAfter`/`DoAfterSpecial`) to S&D's
    /// own timer engine, and flag that the session should re-arm its timer
    /// loop (the loop exits when no timers remain, so a deferral scheduled
    /// while it's idle would otherwise never fire).
    private func scheduleOneShot(after seconds: Double, isScript: Bool, body: String) {
        let timer = MudTimer(
            schedule: .after(max(0, seconds)),
            action: isScript ? .script(body) : .send(body),
            temporary: true
        )
        guard (try? timers.add(timer)) != nil else { return }
        didScheduleTimer = true
    }

    /// Whether a deferred action was scheduled since the last check (read +
    /// cleared by the session so it can restart the timer loop just once).
    public func takeDidScheduleTimer() -> Bool {
        defer { didScheduleTimer = false }
        return didScheduleTimer
    }

    /// Whether a global Lua function of `name` is defined (for tests / sanity).
    public func functionExists(_ name: String) async -> Bool {
        await (try? runtime.string("type(\(name))")) == "function"
    }

    /// Run a Lua chunk in S&D's runtime, returning the effects its output
    /// calls produced (Note/ColourNote/Hyperlink/Send/…). Host-internal effects
    /// (enable/timer/addTrigger/publish) are applied via ``consume`` so the
    /// engine state mirrors a real firing; the raw effects are still returned.
    @discardableResult
    public func run(_ script: String) async throws -> [ScriptEffect] {
        let effects = try await runtime.run(script)
        _ = consume(effects)
        return effects
    }

    /// Evaluate a Lua expression to a string (`tostring`), or nil on error.
    public func evaluate(_ expression: String) async -> String? {
        try? await runtime.string(expression)
    }
}

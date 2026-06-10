import Foundation

/// Ties the scripting layer to a live session: owns a ``LuaRuntime`` and a
/// ``TriggerEngine``, runs incoming lines through the triggers, executes matched
/// scripts with their captures bound, and reports what the host should do
/// (PLAN.md §8.6). Pure decision-making — it returns ``ScriptEffect``s + a gag
/// decision rather than touching the network/scrollback, so it stays testable
/// without a live session; the host (``SessionController``) applies the result.
public actor ScriptEngine {
    let runtime: LuaRuntime
    var triggers = TriggerEngine()
    var aliases = AliasEngine()
    var timers = TimerEngine()
    /// Name → id for runtime/declarative automations, so MUSHclient
    /// `EnableTrigger`/`DeleteTrigger`/`AddTriggerEx`-by-name + `EnableTimer`
    /// resolve. Populated on plugin load + dynamic add.
    var triggerIDsByName: [String: UUID] = [:]
    var timerIDsByName: [String: UUID] = [:]
    var aliasIDsByName: [String: UUID] = [:]
    /// Set when a plugin scheduled a `DoAfter`/`AddTimer` one-shot, so the
    /// session re-arms its timer loop (it idles when no timers remain).
    var didScheduleTimer = false
    /// Native (Swift) plugins folded into the same pipeline as Lua plugins.
    /// Module-internal so the automation extension's reload helpers can reach it.
    var nativePlugins = NativePluginRegistry()
    /// When true, automations are paused: typed input is sent verbatim,
    /// incoming lines pass through, and timers don't fire (Note mode).
    private var suspended = false
    /// Ids of MUSHclient plugins currently loaded, in load order (drives
    /// lifecycle callbacks and the GMCP→`OnPluginBroadcast` bridge).
    var loadedPluginIDs: [String] = []
    /// Trigger/alias/timer id → owning plugin id, so a fired automation's
    /// script runs in its plugin's environment. Absent ⇒ a user automation
    /// (runs in the shared globals).
    var automationOwners: [UUID: String] = [:]

    private static let maxExecuteDepth = 20 // max .execute re-expansions (MUSHclient)

    /// The well-known id of the Aardwolf GMCP-handler plugin. Native GMCP is
    /// handled in Swift, but plugins gate `OnPluginBroadcast` on this id, so
    /// the bridge synthesises broadcasts as if they came from it.
    private static let gmcpHandlerID = "3e7dedbe37e44942dd46d264"

    public init(runtime: LuaRuntime) {
        self.runtime = runtime
    }

    /// Build an engine with a fresh sandboxed runtime.
    public init() throws {
        runtime = try LuaRuntime()
    }

    // MARK: - Triggers

    public func addTrigger(_ trigger: Trigger) throws {
        try triggers.add(trigger)
    }

    public func removeTrigger(id: UUID) {
        triggers.remove(id: id)
    }

    /// Atomically replace a trigger (remove + re-add in one actor call) — not
    /// separate `removeTrigger`/`addTrigger`, whose two `await`s can interleave
    /// with other edit tasks and leave duplicate same-id registrations.
    public func updateTrigger(_ trigger: Trigger) {
        triggers.remove(id: trigger.id)
        try? triggers.add(trigger)
    }

    public func setTriggerEnabled(_ enabled: Bool, id: UUID) {
        triggers.setEnabled(enabled, id: id)
    }

    public func setTriggerGroupEnabled(_ enabled: Bool, group: String) {
        triggers.setGroupEnabled(enabled, group: group)
    }

    public var triggerList: [Trigger] {
        triggers.allTriggers
    }

    // MARK: - Aliases

    public func addAlias(_ alias: Alias) throws {
        try aliases.add(alias)
    }

    public func removeAlias(id: UUID) {
        aliases.remove(id: id)
    }

    /// Atomically replace an alias (see ``updateTrigger(_:)`` for why).
    public func updateAlias(_ alias: Alias) {
        aliases.remove(id: alias.id)
        try? aliases.add(alias)
    }

    public func setAliasEnabled(_ enabled: Bool, id: UUID) {
        aliases.setEnabled(enabled, id: id)
    }

    public func setAliasGroupEnabled(_ enabled: Bool, group: String) {
        aliases.setGroupEnabled(enabled, group: group)
    }

    public var aliasList: [Alias] {
        aliases.allAliases
    }

    // MARK: - Timers

    @discardableResult
    public func addTimer(_ timer: MudTimer, now: Date = Date()) throws -> UUID {
        try timers.add(timer, now: now)
    }

    public func removeTimer(id: UUID) {
        timers.remove(id: id)
    }

    /// Atomically replace a timer (see ``updateTrigger(_:)`` for why).
    public func updateTimer(_ timer: MudTimer, now: Date = Date()) {
        timers.remove(id: timer.id)
        try? timers.add(timer, now: now)
    }

    public func setTimerEnabled(_ enabled: Bool, id: UUID) {
        timers.setEnabled(enabled, id: id)
    }

    public func setTimerGroupEnabled(_ enabled: Bool, group: String) {
        timers.setGroupEnabled(enabled, group: group)
    }

    public var timerList: [MudTimer] {
        timers.allTimers
    }

    /// The earliest instant a timer is due, or `nil` when none are
    /// scheduled. The host sleeps until this, then calls ``fireDueTimers``.
    public func nextTimerDeadline() -> Date? {
        timers.nextDeadline()
    }

    /// Fire every timer due at `now`, returning the effects in order
    /// (sends + script effects). Recurring timers reschedule; one-shots are
    /// removed. Script errors surface as red notes.
    public func fireDueTimers(at now: Date = Date()) async -> [ScriptEffect] {
        // While suspended (Note mode), timers don't fire.
        if suspended { return [] }
        var effects: [ScriptEffect] = []
        for firing in timers.due(at: now) {
            if let send = firing.send, !send.isEmpty {
                effects.append(.send(send))
            }
            if let script = firing.script {
                await effects.append(contentsOf: runOwnedScript(
                    script, owner: automationOwners[firing.timerID], matches: [], named: [:]
                ))
            }
        }
        return effects
    }

    // MARK: - Native plugins

    /// Register a native (Swift) plugin. Returns its `install()` effects so
    /// the host can apply them (typically empty at app-setup time).
    @discardableResult
    public func registerNativePlugin(_ plugin: any NativePlugin, enabled: Bool = true) -> [ScriptEffect] {
        nativePlugins.register(plugin, enabled: enabled)
    }

    /// Enable/disable a native plugin by id (re-enabling re-runs `install()`).
    @discardableResult
    public func setNativePluginEnabled(_ enabled: Bool, id: String) -> [ScriptEffect] {
        nativePlugins.setEnabled(enabled, id: id)
    }

    /// Registered native plugins' info + enabled state (Plugins window).
    public func nativePluginListing() -> [NativePluginInfo] {
        nativePlugins.listing
    }

    /// Route a `CallPlugin`-style call to a native plugin by id.
    public func callNativePlugin(id: String, function: String, arguments: [LuaValue]) -> [LuaValue] {
        nativePlugins.call(id: id, function: function, arguments: arguments)
    }

    /// Fire `connect()` on enabled native plugins (on session connect).
    public func connectNativePlugins() -> [ScriptEffect] {
        nativePlugins.connect()
    }

    /// Pause/resume all automations (triggers/aliases/timers/native). While
    /// suspended, input is sent verbatim and incoming lines pass through.
    public func setSuspended(_ value: Bool) {
        suspended = value
    }

    /// A native plugin's serialized state (for persistence).
    public func nativePluginState(id: String) -> Data? {
        nativePlugins.persistentState(id: id)
    }

    /// Restore saved per-world state into registered native plugins.
    public func restoreNativePluginStates(_ states: [String: Data]) {
        nativePlugins.restore(states: states)
    }

    /// Apply persisted enabled/disabled flags to registered native plugins.
    public func applyNativePluginEnabled(_ enabledByID: [String: Bool]) {
        nativePlugins.applyEnabled(enabledByID)
    }

    // MARK: - Bulk load

    /// Load a persisted ``ScriptDocument`` into the live engines. Invalid
    /// entries (e.g. a malformed regex) are skipped rather than aborting the
    /// whole load, so one bad rule can't disable a user's entire script set.
    public func load(_ document: ScriptDocument, now: Date = Date()) {
        for trigger in document.triggers {
            try? triggers.add(trigger)
        }
        for alias in document.aliases {
            try? aliases.add(alias)
        }
        for timer in document.timers {
            try? timers.add(timer, now: now)
        }
    }

    /// Replace the whole automation set with `document`'s (e.g. on world change);
    /// runtime-only automations clear with the old set. Lua globals/handlers stay
    /// intact — only the trigger/alias/timer tables reset; host restarts the loop.
    public func reload(_ document: ScriptDocument, now: Date = Date()) async {
        triggers = TriggerEngine()
        aliases = AliasEngine()
        timers = TimerEngine()
        loadedPluginIDs.removeAll()
        automationOwners.removeAll()
        await runtime.clearPluginEnvironments()
        load(document, now: now)
    }

    // MARK: - Plugins

    /// Load a parsed MUSHclient plugin: own Lua env, scoped variables + context,
    /// compat shim, run its `<script>`, register its (owner-tagged) automations,
    /// then `OnPluginInstall`. Returns the install effects.
    @discardableResult
    public func loadPlugin(
        _ plugin: MUSHclientPlugin,
        context: PluginContext? = nil
    ) async -> [ScriptEffect] {
        var resolved = context ?? PluginContext(pluginID: plugin.id, pluginName: plugin.name)
        // Carry the plugin's version so `GetPluginInfo(id, 19)` resolves (some
        // plugins print it on install and concat-crash on a nil otherwise).
        resolved.version = plugin.version
        if resolved.pluginName.isEmpty { resolved.pluginName = plugin.name }
        await runtime.createPluginEnvironment(plugin.id)
        await runtime.setPluginContext(resolved)
        try? await runtime.loadCompatShim()

        // Register any AddTriggerEx/AddAlias/AddTimer/DoAfter issued while the
        // script loads (owner-scoped, so callbacks run in this plugin's env).
        var effects = await consumeRegistrations(
            runtime.loadPluginScript(plugin.script, pluginID: plugin.id),
            owner: plugin.id
        )
        for trigger in plugin.triggers {
            try? triggers.add(trigger)
            automationOwners[trigger.id] = plugin.id
            if let name = trigger.name { triggerIDsByName[name] = trigger.id }
        }
        for alias in plugin.aliases {
            try? aliases.add(alias)
            automationOwners[alias.id] = plugin.id
            if let name = alias.name { aliasIDsByName[name] = alias.id }
        }
        for timer in plugin.timers {
            try? timers.add(timer)
            automationOwners[timer.id] = plugin.id
            if let name = timer.label { timerIDsByName[name] = timer.id }
        }
        if !loadedPluginIDs.contains(plugin.id) { loadedPluginIDs.append(plugin.id) }
        // OnPluginInstall commonly registers triggers/aliases/timers (dinv does
        // at init); consume those registrations too rather than leaking them.
        await effects.append(contentsOf: consumeRegistrations(
            runtime.callPluginCallback(plugin.id, "OnPluginInstall"),
            owner: plugin.id
        ))
        return effects
    }

    /// Fire `OnPluginConnect` on every loaded plugin (in its own env).
    public func connectPlugins() async -> [ScriptEffect] {
        await fireCallbackOnAll("OnPluginConnect")
    }

    /// Fire `OnPluginSaveState` then `OnPluginDisconnect` on every loaded
    /// plugin (the host persists the variable snapshot separately).
    public func disconnectPlugins() async -> [ScriptEffect] {
        var effects = await fireCallbackOnAll("OnPluginSaveState")
        await effects.append(contentsOf: fireCallbackOnAll("OnPluginDisconnect"))
        return effects
    }

    /// Fire `OnPluginSaveState` on every loaded plugin without disconnecting —
    /// MUSHclient also saves state outside disconnect (world save, autosave).
    /// Called on app termination so quitting while connected doesn't lose
    /// plugin state changed since connect (`ldb on` was lost this way).
    public func savePluginState() async -> [ScriptEffect] {
        await fireCallbackOnAll("OnPluginSaveState")
    }

    /// Invoke a plugin lifecycle callback (`OnPluginConnect`, … ) by name.
    @discardableResult
    public func callGlobal(_ name: String, _ arguments: [LuaValue] = []) async -> [ScriptEffect] {
        await runtime.callGlobal(name, arguments)
    }

    /// Fire a plugin's stored `async` callback with the HTTP response.
    public func completeHTTP(_ request: HTTPRequest, _ response: HTTPResponse) async -> [ScriptEffect] {
        await runtime.completeHTTPRequest(request, response)
    }

    /// Constrain `sqlite3.open` (the lsqlite3 binding) to `directory` — the
    /// per-profile world-data dir for the mapper DB + plugins' SQLite stores.
    /// `nil` re-closes file access.
    public func setSQLiteDirectory(_ directory: String?) async {
        await runtime.setSQLiteDirectory(directory)
    }

    // App-provided I/O hooks (dialog + clipboard) live in
    // `ScriptEngine+Providers.swift`.

    /// Install the accelerator registrar (plugin keybinds → MacroEngine).
    public func setAcceleratorRegistrar(_ registrar: (@Sendable (Macro) -> Void)?) async {
        await runtime.setAcceleratorRegistrar(registrar)
    }

    /// Register a helper library available to `require name`.
    public func registerModule(_ name: String, source: String) async {
        await runtime.registerModule(name, source: source)
    }

    /// Register several helper libraries at once.
    public func registerModules(_ modules: [String: String]) async {
        await runtime.registerModules(modules)
    }

    /// Set the directories `require`/`dofile` may read `.lua` files from.
    public func setModuleSearchPaths(_ paths: [String]) async {
        await runtime.setModuleSearchPaths(paths)
    }

    // MARK: - Input expansion

    /// Expand a typed line through the aliases → effects. No match → sent
    /// verbatim. `.execute` re-expands (depth-guarded); `.script` runs Lua;
    /// `.output` echoes locally.
    public func expandInput(_ input: String) async -> [ScriptEffect] {
        await expandInput(input, depth: 0)
    }

    private func expandInput(_ input: String, depth: Int) async -> [ScriptEffect] {
        // While suspended (Note mode), input goes straight to the MUD.
        if suspended { return [.send(input)] }
        let firings = aliases.match(input)
        guard !firings.isEmpty else {
            // No user alias matched — offer the command to native plugins
            // before sending it verbatim.
            if let effects = nativePlugins.handleCommand(input) { return effects }
            return [.send(input)]
        }

        var effects: [ScriptEffect] = []
        for firing in firings {
            guard let send = firing.send else { continue }
            switch firing.target {
            case .world:
                effects.append(.send(send))
            case .output:
                effects.append(.echo(send))
            case .script:
                await effects.append(contentsOf: runOwnedScript(
                    send,
                    owner: automationOwners[firing.aliasID],
                    matches: firing.match.captures,
                    named: firing.match.named
                ))
            case .execute:
                if depth < Self.maxExecuteDepth {
                    await effects.append(contentsOf: expandInput(send, depth: depth + 1))
                } else {
                    effects.append(.note(
                        text: "alias execute recursion limit (\(Self.maxExecuteDepth)) reached",
                        foreground: "red",
                        background: nil
                    ))
                }
            }
        }
        return effects
    }

    // MARK: - Processing

    /// Run `line` through the triggers, returning the gag decision and the
    /// effects (trigger sends + script effects, in order). Script errors
    /// surface as red notes rather than aborting.
    public func process(line text: String) async -> LineDisposition {
        await process(Line(id: LineID(0), text: text))
    }

    /// Styled-line entry point: triggers match `line.text` (and get its colour
    /// runs as `styles`); native plugins receive the full styled ``Line``.
    public func process(_ line: Line) async -> LineDisposition {
        // While suspended (Note mode), lines pass through untouched.
        if suspended { return LineDisposition() }
        var disposition = LineDisposition()
        // Highlights collected from firings, applied to the *displayed* line
        // after native plugins have had their say (they may replace it).
        var highlights: [(highlight: TriggerHighlight, matchRange: Range<Int>?)] = []
        for firing in triggers.process(line.text) {
            if firing.gag { disposition.gag = true }
            if let highlight = firing.highlight {
                highlights.append((highlight, firing.match.utf16Range))
            }
            if let send = firing.send, !send.isEmpty {
                // D-105: route the expanded send per the trigger's target.
                disposition.effects.append(Self.sendEffect(send, target: firing.target))
            }
            if let script = firing.script {
                let owner = automationOwners[firing.triggerID]
                // Plugin triggers: %1/%0/%<name> in the body are substituted with
                // (Lua-escaped) captures before it runs; user scripts (no owner)
                // run verbatim so a literal `%` survives.
                let body = owner == nil ? script : firing.match.expandForScript(script)
                await disposition.effects.append(contentsOf: runOwnedScript(
                    body,
                    owner: owner,
                    matches: firing.match.captures,
                    named: firing.match.named,
                    styles: ScriptStyleRun.mushStyles(text: line.text, runs: line.runs)
                ))
            }
        }
        // Fold native plugins' reactions (gag / effects / a rewritten line).
        let native = nativePlugins.onLine(line)
        if native.gag { disposition.gag = true }
        disposition.effects.append(contentsOf: native.effects)
        disposition.replacement = native.replacement
        // Trigger highlights (D-105) restyle whatever will be displayed.
        return Self.applyingHighlights(highlights, to: disposition, original: line)
    }

    /// Run a trigger/alias script: in the owning plugin's environment when
    /// `owner` is set, otherwise in the shared globals (a user script).
    private func runOwnedScript(
        _ script: String,
        owner: String?,
        matches: [String],
        named: [String: String],
        styles: [ScriptStyleRun] = []
    ) async -> [ScriptEffect] {
        let raw: [ScriptEffect] = if let owner {
            await runtime.runPluginScript(
                script, pluginID: owner, matches: matches, named: named, styles: styles
            )
        } else {
            await runScript(script, matches: matches, named: named, styles: styles)
        }
        // Apply programmatic automation (AddTimer/AddTriggerEx/…); pass the rest on.
        return consumeRegistrations(raw, owner: owner)
    }

    /// Project a GMCP message into the live `proteles.gmcp` table, fire its
    /// `gmcp.*` events, and (with MUSHclient plugins loaded) synthesise the
    /// handler's `OnPluginBroadcast(1, id, "GMCP", package)`. Returns effects.
    public func applyGMCP(package: String, json: String) async -> [ScriptEffect] {
        var effects = await runtime.applyGMCP(package: package, json: json)
        await effects.append(contentsOf: fireCallbackOnAll("OnPluginBroadcast", [
            .number(1),
            .string(Self.gmcpHandlerID),
            .string("GMCP"),
            .string(package)
        ]))
        effects.append(contentsOf: nativePlugins.onGMCP(package: package, json: json))
        return effects
    }

    /// Offer a command about to be sent to every plugin's `OnPluginSend(text)`
    /// (MUSHclient's send hook). Returns whether it's `blocked` + the callbacks'
    /// effects (dinv's `dbot.execute` bypass: strip a `DINV_BYPASS` line, re-send
    /// bare, return false to drop the prefixed one).
    public func fireOnPluginSend(_ text: String) async -> (blocked: Bool, effects: [ScriptEffect]) {
        guard !suspended else { return (false, []) }
        var effects: [ScriptEffect] = []
        var blocked = false
        for id in loadedPluginIDs {
            let (raw, allow) = await runtime.callPluginSend(id, text)
            effects.append(contentsOf: consumeRegistrations(raw, owner: id))
            if !allow { blocked = true }
        }
        return (blocked, effects)
    }

    /// Re-fire a GMCP `OnPluginBroadcast(1, handlerID, "GMCP", package)` for a
    /// package already in `proteles.gmcp` (no re-apply) — nudges a plugin loaded
    /// *after* its trigger package arrived (dinv inits on a char.base-while-active).
    public func deliverGMCPBroadcast(package: String) async -> [ScriptEffect] {
        await fireCallbackOnAll("OnPluginBroadcast", [
            .number(1),
            .string(Self.gmcpHandlerID),
            .string("GMCP"),
            .string(package)
        ])
    }

    /// Deliver a mapper broadcast (e.g. 500 `found_paths`, 501 `unfound_paths`)
    /// to every plugin's `OnPluginBroadcast`, as if the native mapper had
    /// called `BroadcastPlugin(id, text)`.
    public func deliverMapperBroadcast(id: Int, text: String) async -> [ScriptEffect] {
        await fireCallbackOnAll("OnPluginBroadcast", [
            .number(Double(id)),
            .string(Mapper.pluginID),
            .string("GMCP Mapper"),
            .string(text)
        ])
    }

    // MARK: - Scoped variables

    /// Hydrate the runtime's scoped variables (e.g. from disk on connect).
    public func loadVariables(_ all: [String: [String: String]]) async {
        await runtime.loadVariables(all)
    }

    /// A snapshot of every scope's variables (for persistence).
    public func variablesSnapshot() async -> [String: [String: String]] {
        await runtime.variablesSnapshot()
    }

    /// Set the scope `getVar`/`setVar`/`deleteVar` operate on.
    public func setVariableScope(_ scope: String) async {
        await runtime.setVariableScope(scope)
    }

    /// Set the ambient context `proteles.info`/`proteles.pluginID` report.
    public func setPluginContext(_ context: PluginContext) async {
        await runtime.setPluginContext(context)
    }

    /// Update the live connection state reported by `proteles.isConnected`.
    public func setConnected(_ value: Bool) async {
        await runtime.setConnected(value)
    }

    /// Install the MUSHclient compatibility globals (`Send`, `Note`,
    /// `ColourNote`, `GetVariable`, `GetInfo`, …) on top of `proteles.*`.
    public func loadCompatShim() async throws {
        try await runtime.loadCompatShim()
    }

    /// The scopes whose variables changed since the last call (clears the
    /// set), so the host persists only what changed.
    public func takeDirtyVariableScopes() async -> Set<String> {
        await runtime.takeDirtyVariableScopes()
    }

    /// Run an arbitrary script (e.g. from an alias or a command), returning
    /// its effects. Errors surface as a red note.
    @discardableResult
    public func run(_ script: String) async -> [ScriptEffect] {
        await runScript(script, matches: [], named: [:])
    }

    // MARK: - Private

    private func runScript(
        _ script: String,
        matches: [String],
        named: [String: String],
        styles: [ScriptStyleRun] = []
    ) async -> [ScriptEffect] {
        do {
            return try await runtime.runScript(script, matches: matches, named: named, styles: styles)
        } catch {
            return [.note(text: "Script error: \(error)", foreground: "red", background: nil)]
        }
    }
}

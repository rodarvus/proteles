import Foundation

/// Ties the scripting layer to a live session: owns a ``LuaRuntime`` and a
/// ``TriggerEngine``, runs incoming lines through the triggers, executes
/// matched scripts with their captures bound, and reports what the host
/// should do (PLAN.md §8.6).
///
/// Pure decision-making — like the engines it composes, it returns
/// ``ScriptEffect``s and a gag decision rather than touching the network or
/// scrollback itself, so it stays testable without a live session. The host
/// (``SessionController``) applies the result.
public actor ScriptEngine {
    /// What to do with a processed line.
    public struct LineDisposition: Sendable, Equatable {
        /// Omit the line from output.
        public var gag: Bool
        /// Effects produced by matched triggers / their scripts, in order.
        public var effects: [ScriptEffect]
        /// A rewritten line to display *instead* of the original (e.g. a
        /// text substitution), preserving the original id/timestamp. `nil`
        /// leaves the incoming line unchanged.
        public var replacement: Line?

        public init(gag: Bool = false, effects: [ScriptEffect] = [], replacement: Line? = nil) {
            self.gag = gag
            self.effects = effects
            self.replacement = replacement
        }
    }

    private let runtime: LuaRuntime
    private var triggers = TriggerEngine()
    private var aliases = AliasEngine()
    private var timers = TimerEngine()
    /// Native (Swift) plugins folded into the same pipeline as Lua plugins.
    private var nativePlugins = NativePluginRegistry()
    /// When true, automations are paused: typed input is sent verbatim,
    /// incoming lines pass through, and timers don't fire (Note mode).
    private var suspended = false
    /// Ids of MUSHclient plugins currently loaded, in load order (drives
    /// lifecycle callbacks and the GMCP→`OnPluginBroadcast` bridge).
    private var loadedPluginIDs: [String] = []
    /// Trigger/alias/timer id → owning plugin id, so a fired automation's
    /// script runs in its plugin's environment. Absent ⇒ a user automation
    /// (runs in the shared globals).
    private var automationOwners: [UUID: String] = [:]

    /// Max `.execute` re-expansions before bailing (MUSHclient's value).
    private static let maxExecuteDepth = 20

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

    /// Atomically replace a trigger (remove + re-add in a single actor call).
    /// The editor's live-apply must use this rather than separate
    /// `removeTrigger`/`addTrigger` calls: two `await`s can interleave with
    /// other in-flight edit tasks (actor reentrancy) and leave duplicate
    /// registrations with the same id — the cause of a trigger firing N×.
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

    /// Pause/resume all automations (triggers/aliases/timers/native). While
    /// suspended, input is sent verbatim and incoming lines pass through.
    public func setSuspended(_ value: Bool) {
        suspended = value
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

    /// Replace the entire automation set with `document`'s (e.g. when the
    /// active world changes). Any runtime-only automations a script created
    /// are cleared along with the old set. The Lua runtime's globals and
    /// event handlers are left intact — only the trigger/alias/timer tables
    /// reset. The host should restart its timer loop afterwards.
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

    /// Load a parsed MUSHclient plugin into the live engines: give it its own
    /// Lua environment (so its globals don't collide with other plugins),
    /// scope its variables + ambient context, install the compat shim, run
    /// its `<script>` in that env, register its triggers/aliases/timers
    /// (tagged with the plugin as owner so they later run in the same env),
    /// then invoke `OnPluginInstall`. Returns the install effects.
    @discardableResult
    public func loadPlugin(
        _ plugin: MUSHclientPlugin,
        context: PluginContext? = nil
    ) async -> [ScriptEffect] {
        let resolved = context ?? PluginContext(pluginID: plugin.id, pluginName: plugin.name)
        await runtime.createPluginEnvironment(plugin.id)
        await runtime.setVariableScope(plugin.id)
        await runtime.setPluginContext(resolved)
        try? await runtime.loadCompatShim()

        var effects = await runtime.loadPluginScript(plugin.script, pluginID: plugin.id)
        for trigger in plugin.triggers {
            try? triggers.add(trigger)
            automationOwners[trigger.id] = plugin.id
        }
        for alias in plugin.aliases {
            try? aliases.add(alias)
            automationOwners[alias.id] = plugin.id
        }
        for timer in plugin.timers {
            try? timers.add(timer)
            automationOwners[timer.id] = plugin.id
        }
        if !loadedPluginIDs.contains(plugin.id) { loadedPluginIDs.append(plugin.id) }
        await effects.append(contentsOf: runtime.callPluginCallback(plugin.id, "OnPluginInstall"))
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

    /// Invoke `name` on every loaded plugin's environment, in load order.
    private func fireCallbackOnAll(_ name: String, _ arguments: [LuaValue] = []) async -> [ScriptEffect] {
        var effects: [ScriptEffect] = []
        for pluginID in loadedPluginIDs {
            await effects.append(contentsOf: runtime.callPluginCallback(pluginID, name, arguments))
        }
        return effects
    }

    /// Invoke a plugin lifecycle callback (`OnPluginConnect`, … ) by name.
    @discardableResult
    public func callGlobal(_ name: String, _ arguments: [LuaValue] = []) async -> [ScriptEffect] {
        await runtime.callGlobal(name, arguments)
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

    /// Expand a typed line through the aliases, returning the effects to
    /// apply. If no alias matches, the line is sent verbatim. `.execute`
    /// targets re-expand (depth-guarded); `.script` runs Lua; `.output`
    /// echoes locally.
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

    /// Styled-line entry point: triggers match `line.text`, and native
    /// plugins receive the full styled ``Line`` so they can rewrite it
    /// (text substitution) while preserving per-segment colour.
    public func process(_ line: Line) async -> LineDisposition {
        // While suspended (Note mode), lines pass through untouched.
        if suspended { return LineDisposition() }
        var disposition = LineDisposition()
        for firing in triggers.process(line.text) {
            if firing.gag { disposition.gag = true }
            if let send = firing.send, !send.isEmpty {
                disposition.effects.append(.send(send))
            }
            if let script = firing.script {
                await disposition.effects.append(contentsOf: runOwnedScript(
                    script,
                    owner: automationOwners[firing.triggerID],
                    matches: firing.match.captures,
                    named: firing.match.named
                ))
            }
        }
        // Fold native plugins' reactions (gag / effects / a rewritten line).
        let native = nativePlugins.onLine(line)
        if native.gag { disposition.gag = true }
        disposition.effects.append(contentsOf: native.effects)
        disposition.replacement = native.replacement
        return disposition
    }

    /// Run a trigger/alias script: in the owning plugin's environment when
    /// `owner` is set, otherwise in the shared globals (a user script).
    private func runOwnedScript(
        _ script: String,
        owner: String?,
        matches: [String],
        named: [String: String]
    ) async -> [ScriptEffect] {
        if let owner {
            return await runtime.runPluginScript(script, pluginID: owner, matches: matches, named: named)
        }
        return await runScript(script, matches: matches, named: named)
    }

    /// Project a GMCP message into the live `proteles.gmcp` table, fire its
    /// `gmcp.*` events, and — when MUSHclient plugins are loaded — synthesise
    /// the GMCP-handler's `OnPluginBroadcast(1, handlerID, "GMCP", package)`
    /// that plugins like `aard_prompt_fixer` wait on. Returns all effects.
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
        named: [String: String]
    ) async -> [ScriptEffect] {
        do {
            return try await runtime.runScript(script, matches: matches, named: named)
        } catch {
            return [.note(text: "Script error: \(error)", foreground: "red", background: nil)]
        }
    }
}

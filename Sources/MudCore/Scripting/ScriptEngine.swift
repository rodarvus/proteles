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

        public init(gag: Bool = false, effects: [ScriptEffect] = []) {
            self.gag = gag
            self.effects = effects
        }
    }

    private let runtime: LuaRuntime
    private var triggers = TriggerEngine()
    private var aliases = AliasEngine()
    private var timers = TimerEngine()

    /// Max `.execute` re-expansions before bailing (MUSHclient's value).
    private static let maxExecuteDepth = 20

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
        var effects: [ScriptEffect] = []
        for firing in timers.due(at: now) {
            if let send = firing.send, !send.isEmpty {
                effects.append(.send(send))
            }
            if let script = firing.script {
                await effects.append(contentsOf: runScript(script, matches: [], named: [:]))
            }
        }
        return effects
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
    public func reload(_ document: ScriptDocument, now: Date = Date()) {
        triggers = TriggerEngine()
        aliases = AliasEngine()
        timers = TimerEngine()
        load(document, now: now)
    }

    // MARK: - Plugins

    /// Load a parsed MUSHclient plugin into the live engines: scope its
    /// variables + ambient context to the plugin, install the compat shim,
    /// run its `<script>` (defining its globals), register its
    /// triggers/aliases/timers, then invoke `OnPluginInstall`. Returns the
    /// effects produced during install.
    ///
    /// This is the host scaffolding; `require`/`dofile` + helper libraries
    /// and the GMCP→`OnPluginBroadcast` bridge are later sub-increments, so
    /// plugins that pull in helper libs won't fully initialise yet.
    @discardableResult
    public func loadPlugin(
        _ plugin: MUSHclientPlugin,
        context: PluginContext? = nil
    ) async -> [ScriptEffect] {
        let resolved = context ?? PluginContext(pluginID: plugin.id, pluginName: plugin.name)
        await runtime.setVariableScope(plugin.id)
        await runtime.setPluginContext(resolved)
        try? await runtime.loadCompatShim()

        var effects = await run(plugin.script)
        for trigger in plugin.triggers {
            try? triggers.add(trigger)
        }
        for alias in plugin.aliases {
            try? aliases.add(alias)
        }
        for timer in plugin.timers {
            try? timers.add(timer)
        }
        await effects.append(contentsOf: runtime.callGlobal("OnPluginInstall"))
        return effects
    }

    /// Invoke a plugin lifecycle callback (`OnPluginConnect`, … ) by name.
    @discardableResult
    public func callGlobal(_ name: String, _ arguments: [LuaValue] = []) async -> [ScriptEffect] {
        await runtime.callGlobal(name, arguments)
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
        let firings = aliases.match(input)
        guard !firings.isEmpty else { return [.send(input)] }

        var effects: [ScriptEffect] = []
        for firing in firings {
            guard let send = firing.send else { continue }
            switch firing.target {
            case .world:
                effects.append(.send(send))
            case .output:
                effects.append(.echo(send))
            case .script:
                await effects.append(contentsOf: runScript(
                    send,
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
    public func process(line: String) async -> LineDisposition {
        var disposition = LineDisposition()
        for firing in triggers.process(line) {
            if firing.gag { disposition.gag = true }
            if let send = firing.send, !send.isEmpty {
                disposition.effects.append(.send(send))
            }
            if let script = firing.script {
                await disposition.effects.append(contentsOf: runScript(
                    script,
                    matches: firing.match.captures,
                    named: firing.match.named
                ))
            }
        }
        return disposition
    }

    /// Project a GMCP message into the live `proteles.gmcp` table and fire
    /// its `gmcp.*` events, returning any effects the handlers recorded.
    public func applyGMCP(package: String, json: String) async -> [ScriptEffect] {
        await runtime.applyGMCP(package: package, json: json)
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

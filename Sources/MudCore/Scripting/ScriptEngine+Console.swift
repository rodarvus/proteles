public extension ScriptEngine {
    /// Evaluate one-off **console** input (the `/lua …` command, #41, and the
    /// Lua Console window) on the live runtime, returning the effects to
    /// surface (captured `print`/`Note` output, an `= value` echo for
    /// expressions, or a single red error note). `inPlugin` runs the code in
    /// that loaded plugin's sandbox environment (the console's environment
    /// picker). See ``LuaRuntime/evaluateConsole(_:pluginID:)``.
    @discardableResult
    func evaluateConsole(_ code: String, inPlugin pluginID: String? = nil) async -> [ScriptEffect] {
        await runtime.evaluateConsole(code, pluginID: pluginID)
    }

    /// One pickable Lua Console environment: a loaded shim plugin.
    struct ConsoleEnvironment: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The loaded plugin environments console code can run in, in load order
    /// (plus the implicit user environment, which is `inPlugin: nil`).
    func consoleEnvironments() async -> [ConsoleEnvironment] {
        var environments: [ConsoleEnvironment] = []
        for id in loadedPluginIDs {
            let name = await runtime.pluginDisplayName(id)
            environments.append(ConsoleEnvironment(id: id, name: name))
        }
        return environments
    }
}

public extension ScriptEngine {
    /// Mark a natively-bridged MUSHclient plugin id present/absent for the
    /// shim's `IsPluginInstalled` (the session calls this as the mapper / S&D
    /// host attach or a world reload drops them).
    func setBridgedPlugin(_ id: String, installed: Bool) async {
        await runtime.setBridgedPlugin(id, installed: installed)
    }

    /// Mirror S&D's shim-readable state (from a `.searchAndDestroyState`
    /// effect) into the shim runtime, so plugin `CallPlugin` reads of
    /// `target_as_json`/`targets_as_json`/`goto_list_count` answer
    /// synchronously from the latest pushed snapshot.
    func setSearchAndDestroyState(target: String?, targets: String?, gotoCount: String?) async {
        await runtime.setSearchAndDestroyShimState(target: target, targets: targets, gotoCount: gotoCount)
    }
}

public extension ScriptEngine {
    /// Pause/resume all automations (triggers/aliases/timers/native). While
    /// suspended, input is sent verbatim and incoming lines pass through
    /// (Note mode). The dispatch path also reads ``automationsSuspended`` to
    /// bypass mapper/S&D interception while a note is being written.
    func setSuspended(_ value: Bool) {
        suspended = value
    }

    /// Whether automations are currently suspended — read by the dispatch
    /// path (note-text bypass), tests, and diagnostics.
    var automationsSuspended: Bool {
        suspended
    }
}

public extension ScriptEngine {
    /// Whether script errors also surface as red notes in the main output
    /// (they always reach the Lua Console's stream) — Settings ▸ Input (#16).
    func setErrorNotesVisible(_ visible: Bool) async {
        runtime.errorNotesVisible = visible
    }
}

import Foundation

/// Applying scripting decisions (triggers/aliases) to the live session.
public extension SessionController {
    /// Run a received line through the script engine (if any), then append
    /// it unless a trigger gagged it. Trigger sends/echoes are applied
    /// afterwards so echoes land just below the line that produced them.
    internal func appendLineThroughScripts(_ line: Line) async {
        guard let scriptEngine else {
            await scrollbackStore.append(line)
            return
        }
        let disposition = await scriptEngine.process(line: line.text)
        if !disposition.gag {
            await scrollbackStore.append(line)
        }
        await applyScriptEffects(disposition.effects)
    }

    /// Apply the effects a script produced: sends go to the MUD, echoes/notes
    /// to the scrollback.
    internal func applyScriptEffects(_ effects: [ScriptEffect]) async {
        for effect in effects {
            switch effect {
            case .send(let command), .execute(let command), .sendNoEcho(let command):
                try? await sendLine(command)
            case .echo(let text):
                await scrollbackStore.append(Line(id: LineID(0), text: text))
            case .note(let text, let foreground, let background):
                await scrollbackStore.append(Line(
                    id: LineID(0),
                    text: text,
                    runs: Self.noteRuns(text, foreground: foreground, background: background)
                ))
            case .sendGMCP(let payload):
                try? await sendRaw(GMCPMessage.encode(payload: payload))
            case .echoAard(let coded):
                await scrollbackStore.append(AardwolfColor.styledLine(from: coded))
            case .echoAnsi(let ansi):
                await scrollbackStore.append(Self.ansiLine(ansi))
            }
        }
    }

    // MARK: - Script set

    /// Replace the live script set (triggers/aliases/timers) with
    /// `document`'s and restart the timer loop. Called when the active world
    /// changes. No-op without a script engine.
    func loadScripts(_ document: ScriptDocument) async {
        guard let scriptEngine else { return }
        await scriptEngine.reload(document)
        restartTimerLoop()
    }

    /// Attach a per-world variable store and hydrate the engine's scoped
    /// variables from it. Call on connect, before loading plugins (so their
    /// `OnPluginInstall` reads persisted values). The store is then written
    /// through as variables change.
    func attachVariableStore(_ store: VariableStore) async {
        guard let scriptEngine else { return }
        variableStore = store
        try? await store.load()
        await scriptEngine.loadVariables(store.scopes)
    }

    /// Persist any variable scopes mutated since the last call to the
    /// attached store. Cheap when nothing changed (no I/O). Called after each
    /// batch of script execution so plugin variables survive relaunches.
    func persistVariablesIfDirty() async {
        guard let variableStore, let scriptEngine else { return }
        let dirty = await scriptEngine.takeDirtyVariableScopes()
        guard !dirty.isEmpty else { return }
        let snapshot = await scriptEngine.variablesSnapshot()
        for scope in dirty {
            try? await variableStore.update(scope: scope, variables: snapshot[scope] ?? [:])
        }
    }

    /// Discover and load every MUSHclient `.xml` plugin in `directory` into
    /// the live engine: parse each, scope it with a ``PluginContext`` rooted
    /// at the directory (so `require`/`dofile`/`GetInfo` resolve there), run
    /// it (firing `OnPluginInstall`), and apply the resulting effects. Call
    /// after ``loadScripts(_:)`` (which resets the engines) and before
    /// connecting. No-op without a script engine or plugins.
    func loadPlugins(fromDirectory directory: URL) async {
        guard let scriptEngine else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let xmlFiles = entries
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !xmlFiles.isEmpty else { return }

        // Plugins resolve their own files (and dofile targets) here.
        await scriptEngine.setModuleSearchPaths([directory.path])
        for url in xmlFiles {
            guard let data = try? Data(contentsOf: url),
                  let plugin = try? MUSHclientPluginLoader.parse(data)
            else { continue }
            let context = PluginContext(
                pluginID: plugin.id,
                pluginName: plugin.name,
                pluginDirectory: directory.path
            )
            await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        }
        // OnPluginInstall may have set variables; persist them.
        await persistVariablesIfDirty()
        // Plugins may have registered timers.
        restartTimerLoop()
    }

    // MARK: - Timers

    /// Add a timer to the script engine and (re)start the driving loop so the
    /// new deadline is picked up. No-op without a script engine.
    @discardableResult
    func addTimer(_ timer: MudTimer) async throws -> UUID? {
        guard let scriptEngine else { return nil }
        let id = try await scriptEngine.addTimer(timer)
        restartTimerLoop()
        return id
    }

    func removeTimer(id: UUID) async {
        guard let scriptEngine else { return }
        await scriptEngine.removeTimer(id: id)
        restartTimerLoop()
    }

    func setTimerEnabled(_ enabled: Bool, id: UUID) async {
        guard let scriptEngine else { return }
        await scriptEngine.setTimerEnabled(enabled, id: id)
        restartTimerLoop()
    }

    /// Atomically replace a timer and restart the loop once. Used by the
    /// editor's live-apply (avoids the remove-then-add reentrancy that can
    /// duplicate registrations).
    func updateTimer(_ timer: MudTimer) async {
        guard let scriptEngine else { return }
        await scriptEngine.updateTimer(timer)
        restartTimerLoop()
    }

    func setTimerGroupEnabled(_ enabled: Bool, group: String) async {
        guard let scriptEngine else { return }
        await scriptEngine.setTimerGroupEnabled(enabled, group: group)
        restartTimerLoop()
    }

    /// Cancel any running timer loop and start a fresh one. Called whenever
    /// the timer set changes so a newly-added earlier deadline interrupts an
    /// in-flight sleep. The loop exits on its own when no timers remain.
    internal func restartTimerLoop() {
        timerTask?.cancel()
        guard let scriptEngine else {
            timerTask = nil
            return
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = await scriptEngine.nextTimerDeadline() else { return }
                let delay = deadline.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { return }
                await self?.applyDueTimers()
            }
        }
    }

    /// Fire the timers due at `now` and apply their effects. Factored out so
    /// tests can drive timer firing deterministically without real sleeping.
    internal func applyDueTimers(at now: Date = Date()) async {
        guard let scriptEngine else { return }
        await applyScriptEffects(scriptEngine.fireDueTimers(at: now))
    }

    /// Render an ANSI-SGR string into a single ``Line`` with styled runs, by
    /// running it through the ``ANSIParser`` (used by the shim's `AnsiNote`,
    /// e.g. `AnsiNote(ColoursToANSI(text))`).
    static func ansiLine(_ ansi: String) -> Line {
        var parser = ANSIParser()
        var text = ""
        var runs: [StyledRun] = []
        let collect: (ANSIEvent) -> Void = { event in
            guard case .text(let segment, let style) = event else { return }
            let start = (text as NSString).length
            text += segment
            let end = (text as NSString).length
            if !style.isDefault, start < end {
                runs.append(StyledRun(utf16Range: start..<end, style: style))
            }
        }
        parser.process(Array(ansi.utf8), emit: collect)
        parser.flush(collect)
        return Line(id: LineID(0), text: text, runs: runs)
    }

    internal static func noteRuns(_ text: String, foreground: String?, background: String?) -> [StyledRun] {
        var style = StyleAttributes.default
        if let foreground, let color = namedColor(foreground) { style.foreground = color }
        if let background, let color = namedColor(background) { style.background = color }
        let length = (text as NSString).length
        guard !style.isDefault, length > 0 else { return [] }
        return [StyledRun(utf16Range: 0..<length, style: style)]
    }

    internal static func namedColor(_ name: String) -> ANSIColor? {
        let names: [String: NamedColor] = [
            "black": .black, "red": .red, "green": .green, "yellow": .yellow,
            "blue": .blue, "magenta": .magenta, "cyan": .cyan, "white": .white
        ]
        return names[name.lowercased()].map { .named($0) }
    }
}

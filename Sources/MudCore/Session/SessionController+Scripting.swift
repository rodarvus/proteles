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
        let disposition = await scriptEngine.process(line)
        if !disposition.gag {
            await scrollbackStore.append(disposition.replacement ?? line)
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
            case .colourNote(let segments):
                await scrollbackStore.append(Self.colourNoteLine(segments))
            case .sendGMCP(let payload):
                try? await sendRaw(GMCPMessage.encode(payload: payload))
            case .echoAard(let coded):
                await scrollbackStore.append(AardwolfColor.styledLine(from: coded))
            case .echoAnsi(let ansi):
                await scrollbackStore.append(Self.ansiLine(ansi))
            default:
                await applyControlEffect(effect)
            }
        }
    }

    /// Apply the non-scrollback "control" effects (engine suspension,
    /// persistence, Aardwolf telnet options, map updates). Split out of
    /// ``applyScriptEffects(_:)`` to keep each switch within the complexity
    /// budget.
    private func applyControlEffect(_ effect: ScriptEffect) async {
        switch effect {
        case .setAutomationsSuspended(let suspended):
            await scriptEngine?.setSuspended(suspended)
        case .persistPluginState(let id):
            await persistNativePluginState(id: id)
        case .aardwolfTelnet(let option, let on):
            try? await sendRaw(Self.aardwolfTelnetBytes(option: option, on: on))
        case .updateMap(let map):
            await mapStore.update(map)
        default:
            break
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

    /// Attach a per-world native-plugin store and hydrate the engine's
    /// native plugins from it (their saved state + enabled flags). Call when
    /// a world loads.
    func attachNativePluginStore(_ store: NativePluginStore) async {
        guard let scriptEngine else { return }
        nativePluginStore = store
        try? await store.load()
        let document = await store.document
        await scriptEngine.restoreNativePluginStates(document.state)
        await scriptEngine.applyNativePluginEnabled(document.enabled)
    }

    /// Attach the per-world live map. Call when a world loads; the GMCP
    /// stream then feeds it room/area/sector updates.
    func attachMapper(_ mapper: Mapper) {
        self.mapper = mapper
    }

    /// Write a native plugin's current serialized state to the attached
    /// store (after a command mutated it).
    func persistNativePluginState(id: String) async {
        guard let nativePluginStore, let scriptEngine else { return }
        let data = await scriptEngine.nativePluginState(id: id)
        try? await nativePluginStore.setState(data, id: id)
    }

    /// Toggle a native plugin and persist the new enabled flag.
    func setNativePluginEnabled(_ enabled: Bool, id: String) async {
        guard let scriptEngine else { return }
        _ = await scriptEngine.setNativePluginEnabled(enabled, id: id)
        try? await nativePluginStore?.setEnabled(enabled, id: id)
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
    /// Frame an Aardwolf telnet-option toggle: `IAC SB 102 <option>
    /// <1=on|2=off> IAC SE`.
    static func aardwolfTelnetBytes(option: Int, on: Bool) -> [UInt8] {
        let iac: UInt8 = 0xFF, sb: UInt8 = 0xFA, se: UInt8 = 0xF0
        let aardwolfOption: UInt8 = 102
        return [iac, sb, aardwolfOption, UInt8(option), on ? 1 : 2, iac, se]
    }

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

    /// Build one ``Line`` from `ColourNote` segments: the texts concatenate
    /// into the line, and each non-default segment gets its own styled run
    /// over its UTF-16 range — so per-segment colours survive.
    internal static func colourNoteLine(_ segments: [NoteSegment]) -> Line {
        var text = ""
        var runs: [StyledRun] = []
        for segment in segments {
            let start = (text as NSString).length
            text += segment.text
            let end = (text as NSString).length
            var style = StyleAttributes.default
            if let fg = segment.foreground, let color = namedColor(fg) { style.foreground = color }
            if let bg = segment.background, let color = namedColor(bg) { style.background = color }
            if !style.isDefault, start < end {
                runs.append(StyledRun(utf16Range: start..<end, style: style))
            }
        }
        return Line(id: LineID(0), text: text, runs: runs)
    }

    /// Resolve a MUSHclient colour string to an ``ANSIColor``: one of the
    /// eight names (`"red"`, `"white"`, …) or a `#RRGGBB` hex value. Returns
    /// `nil` for unrecognised input (rendered as the terminal default).
    internal static func namedColor(_ name: String) -> ANSIColor? {
        if name.hasPrefix("#"), let rgb = hexColor(name) { return rgb }
        let names: [String: NamedColor] = [
            "black": .black, "red": .red, "green": .green, "yellow": .yellow,
            "blue": .blue, "magenta": .magenta, "cyan": .cyan, "white": .white
        ]
        return names[name.lowercased()].map { .named($0) }
    }

    /// Parse a `#RRGGBB` hex colour into an ``ANSIColor/rgb``. `nil` unless
    /// it's exactly six hex digits after the `#`.
    private static func hexColor(_ string: String) -> ANSIColor? {
        let hex = string.dropFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return .rgb(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }
}

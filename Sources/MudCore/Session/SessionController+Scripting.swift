import Foundation

/// Applying scripting decisions (triggers/aliases) to the live session.
public extension SessionController {
    /// Whether `line` should be withheld from the main output given the
    /// blank-line preference: only *completely empty* text (matching the
    /// reference's `^$`, so a whitespace-only line is kept).
    static func omitsFromOutput(_ line: Line, omitBlankLines: Bool) -> Bool {
        omitBlankLines && line.text.isEmpty
    }

    /// Run a received line through the script engine (if any), then append
    /// it unless a trigger gagged it. Trigger sends/echoes are applied
    /// afterwards so echoes land just below the line that produced them.
    internal func appendLineThroughScripts(_ line: Line) async {
        if helpCaptureEnabled, captureHelpLine(line) { return } // Help panel capture
        // Blank-line omission (View menu): triggers/S&D still see the line, but
        // it's withheld from the main output. Checked per line against the
        // current preference.
        let omitBlank = Self.omitsFromOutput(line, omitBlankLines: omitBlankLines)
        guard let scriptEngine else {
            // S&D matches the raw line on its own runtime; its scrape triggers
            // gag their own command output (cp info/check) from the window.
            let sndGag = await applySearchAndDestroyLine(line)
            if !sndGag, !omitBlank { await scrollbackStore.append(line) }
            return
        }
        let disposition = await scriptEngine.process(line)
        // S&D matches the raw line independently of the user's scripts (its own
        // runtime), so feed it the original text regardless of the user gag —
        // and let *its* gag suppress the line too (cp info/check scrape output).
        let sndGag = await applySearchAndDestroyLine(line)
        // Rich Exits: rewrite the tagged exits line into clickable directions,
        // and gag the tag-toggle confirmation. Runs after scripts/S&D so they
        // still see the raw line.
        let (outLine, richExitsGag) = applyRichExits(disposition.replacement ?? line, source: line)
        if !disposition.gag, !sndGag, !omitBlank, !richExitsGag {
            await scrollbackStore.append(outLine)
        }
        await applyScriptEffects(disposition.effects)
        await rearmTimerLoopIfScriptScheduled()
    }

    /// Run a received line through Search-and-Destroy's triggers and apply the
    /// effects it produced (sends, echoes, a re-published model). Returns
    /// whether S&D gagged the line (`omit_from_output`). No-op (false) when no
    /// S&D host is attached.
    @discardableResult
    private func applySearchAndDestroyLine(_ line: Line) async -> Bool {
        guard let searchAndDestroy else { return false }
        // `runs` = MUSHclient's 4th `styles` arg (S&D scan/consider re-render from it).
        let result = await searchAndDestroy.process(line.text, runs: line.runs)
        await applyScriptEffects(result.effects)
        await rearmTimerLoopIfSnDScheduled()
        return result.gag
    }

    /// If S&D scheduled a `DoAfter`/`DoAfterSpecial` one-shot, restart the timer
    /// loop so it fires (the loop exits when no timers remain — an idle deferral).
    internal func rearmTimerLoopIfSnDScheduled() async {
        if await searchAndDestroy?.takeDidScheduleTimer() == true {
            restartTimerLoop()
        }
    }

    /// Same, for the shared script engine: a plugin's `AddTimer`/`DoAfter`
    /// (e.g. via the `wait` helper) schedules a one-shot that must be picked up
    /// even if the timer loop was idle.
    internal func rearmTimerLoopIfScriptScheduled() async {
        if await scriptEngine?.takeDidScheduleTimer() == true {
            restartTimerLoop()
        }
    }

    /// Offer a typed command to Search-and-Destroy's aliases first. Returns
    /// `true` if S&D handled it (effects applied), so the caller skips the
    /// normal alias/verbatim path. No-op (false) without an S&D host.
    func handleSearchAndDestroyCommand(_ command: String) async -> Bool {
        guard let searchAndDestroy,
              let effects = await searchAndDestroy.expandCommand(command)
        else { return false }
        await applyScriptEffects(effects)
        await rearmTimerLoopIfSnDScheduled()
        await persistVariablesIfDirty()
        return true
    }

    /// Attach the live Search-and-Destroy host (already configured + loaded)
    /// and start its timer loop. Call when a world loads.
    func attachSearchAndDestroy(_ host: SearchAndDestroyHost) {
        searchAndDestroy = host
        restartTimerLoop()
    }

    /// Print a system note to the main output (used by UI flows like database
    /// import to report results where the user is actually looking, mirroring
    /// how the reference mapper prints its Notes to the output).
    func echoSystemNote(_ text: String) async {
        await applyScriptEffects([.note(text: text, foreground: "cyan", background: nil)])
    }

    /// Force a Search-and-Destroy campaign/quest detection pass (its
    /// `do_cp_info`). Used by the panel's "Scan now" and the post-connect
    /// auto-scan. No-op without an S&D host.
    func scanSearchAndDestroy() async {
        guard let searchAndDestroy else { return }
        await applyScriptEffects(searchAndDestroy.scanForActivity())
        await rearmTimerLoopIfSnDScheduled()
        await persistVariablesIfDirty()
    }

    /// Apply the effects a script produced: sends go to the MUD, echoes/notes
    /// to the scrollback.
    internal func applyScriptEffects(_ effects: [ScriptEffect]) async {
        for effect in effects {
            switch effect {
            case .send(let command), .sendNoEcho(let command):
                await sendCommandThroughPlugins(command)
            case .execute(let command):
                // MUSHclient's Execute: re-parse through the command pipeline
                // (native mapper / aliases), not a raw send.
                try? await dispatchCommand(command)
            case .echo(let text):
                await appendOutputLines(text) { Line(id: LineID(0), text: $0) }
            case .note(let text, let foreground, let background):
                await appendOutputLines(text) {
                    Line(
                        id: LineID(0),
                        text: $0,
                        runs: Self.noteRuns($0, foreground: foreground, background: background)
                    )
                }
            case .colourNote(let segments):
                logTranscript(.note, segments.map(\.text).joined())
                await scrollbackStore.append(Self.colourNoteLine(segments))
            case .sendGMCP(let payload):
                try? await sendRaw(GMCPMessage.encode(payload: payload))
            case .echoAard(let coded):
                await appendOutputLines(coded) { AardwolfColor.styledLine(from: $0) }
            case .echoAnsi(let ansi):
                await appendOutputLines(ansi) { Self.ansiLine($0) }
            default:
                await applyControlEffect(effect)
            }
        }
    }

    /// Append a Note/echo's text, splitting embedded `\n` into separate lines
    /// (MUSHclient renders them as breaks; trailing `\n` adds no empty line).
    private func appendOutputLines(_ text: String, _ makeLine: (String) -> Line) async {
        logTranscript(.note, text)
        var segments = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if segments.count > 1, segments.last?.isEmpty == true { segments.removeLast() }
        for segment in segments {
            await scrollbackStore.append(makeLine(segment))
        }
    }

    /// Send a command to the MUD, first offering it to plugins' `OnPluginSend`
    /// (MUSHclient's send hook). If any plugin blocks it (returns false), the
    /// raw send is suppressed — the plugin handled it (dinv strips its
    /// `DINV_BYPASS` prefix and re-sends the bare command). The hook's own
    /// effects are applied, re-entrancy-guarded so a re-sending plugin can't
    /// loop. With no script engine, sends straight to the MUD.
    private func sendCommandThroughPlugins(_ command: String) async {
        // While OnPluginSend is processing, a send goes straight to the MUD
        // (MUSHclient's m_bPluginProcessingSend guard) — so the bare command a
        // plugin re-sends from inside the hook (dinv's bypass) isn't re-offered
        // to the hook and re-queued.
        guard let scriptEngine, !pluginProcessingSend else {
            try? await sendLine(command)
            return
        }
        pluginProcessingSend = true
        defer { pluginProcessingSend = false }
        let (blocked, effects) = await scriptEngine.fireOnPluginSend(command)
        if !effects.isEmpty { await applyScriptEffects(effects) }
        if !blocked { try? await sendLine(command) }
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
        case .updateTick(let date):
            await gmcpState.setLastTick(date)
        case .mapperCall(let function, let args):
            await applyMapperCall(function: function, args: args)
        case .publishModel(let json):
            publishedModelsContinuation.yield(json)
        default:
            await applyInboundControlEffect(effect)
        }
    }

    /// MUSHclient `Simulate`: feed `text` back through the inbound pipeline as
    /// if it had arrived from the MUD, so triggers (user + S&D) process it and
    /// it displays. Split on newlines; a single trailing newline doesn't add a
    /// spurious empty line. Used by S&D's `xtest` harness and `notes` header.
    func reinjectSimulated(_ text: String) async {
        var segments = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if segments.count > 1, segments.last?.isEmpty == true { segments.removeLast() }
        for segment in segments {
            await appendLineThroughScripts(Line(id: LineID(0), text: segment))
        }
    }

    /// Run a `CallPlugin(<mapper>, …)` against the native mapper and deliver
    /// any resulting broadcasts (e.g. 500/501 path results) back to plugins
    /// via `OnPluginBroadcast`.
    private func applyMapperCall(function: String, args: [String]) async {
        guard let mapper, let scriptEngine else { return }
        let result = await mapper.handlePluginCall(function, args: args)
        for broadcast in result.broadcasts {
            await applyScriptEffects(scriptEngine.deliverMapperBroadcast(
                id: broadcast.id,
                text: broadcast.text
            ))
        }
    }

    /// Load the vendored **dinv** inventory manager (run verbatim through the
    /// compat shim — D-32). Registers its modules with the engine's loader (so
    /// its `dofile`s resolve from the bundle), then loads `dinv.xml` with a
    /// context whose state dir (`GetInfo(85)`) is `stateDirectory` — the
    /// per-profile world-data dir, which is also the lsqlite3 sandbox root, so
    /// dinv's per-character `dinv.db` lands inside the sandbox. No-op without a
    /// script engine or the bundled assets.
    ///
    /// **Armed, not loaded immediately:** dinv inits on the first `char.base`
    /// broadcast it sees *while the character is active*, and only then opens
    /// its DB and initializes its modules. If loaded at connect time, the
    /// `char.base` broadcasts that arrive during login (state ≠ active) latch
    /// its "GMCP initialized" flag and init never runs. So we record the state
    /// dir and load on the first active `char.status` (see ``loadPendingDinv``).
    func armBundledDinv(stateDirectory: String) {
        pendingDinvStateDirectory = stateDirectory
    }

    /// Load dinv now that the character is active (called from the GMCP path).
    /// After install, replay a `char.base` broadcast so dinv — freshly loaded
    /// with its init flag clear — catches it while active and initializes.
    func loadPendingDinv() async {
        guard !dinvLoaded, let stateDirectory = pendingDinvStateDirectory,
              let scriptEngine, let xml = DinvAssets.pluginXML,
              let plugin = try? MUSHclientPluginLoader.parse(xml: xml)
        else { return }
        dinvLoaded = true
        await scriptEngine.registerModules(DinvAssets.modules)
        let suffixed = stateDirectory.hasSuffix("/") ? stateDirectory : stateDirectory + "/"
        let context = PluginContext(
            pluginID: DinvAssets.pluginID,
            pluginName: "dinv",
            version: "3.0102",
            pluginDirectory: suffixed,
            worldDirectory: suffixed,
            appDirectory: suffixed,
            stateDirectory: suffixed
        )
        await applyScriptEffects(scriptEngine.loadPlugin(plugin, context: context))
        // Replay char.base so dinv — freshly loaded with its init flag clear —
        // catches it while active and runs its init chain.
        await applyScriptEffects(scriptEngine.deliverGMCPBroadcast(package: "char.base"))
        await persistVariablesIfDirty()
        restartTimerLoop()
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

    /// Attach the per-profile world-data directory: the lsqlite3 sandbox root
    /// and `GetInfo(66)` for loaded plugins (so they find the mapper DB and
    /// keep their own SQLite stores here). Call when a world loads.
    func attachWorldDataDirectory(_ path: String) async {
        worldDataDirectory = path
        await scriptEngine?.setSQLiteDirectory(path)
    }

    /// Attach the per-world live map. Call when a world loads; the GMCP
    /// stream then feeds it room/area/sector updates.
    func attachMapper(_ mapper: Mapper) {
        self.mapper = mapper
        mapperNotesTask?.cancel()
        mapperNotesTask = Task { [weak self] in
            guard let stream = await self?.mapper?.subscribeNotes() else { return }
            for await note in stream {
                await self?.echoSystemNote(note)
            }
        }
        for continuation in mapperAttachmentSubscribers.values {
            continuation.yield(mapper)
        }
    }

    /// Stream of attached mappers — yields the current one immediately (if
    /// any) and again on each later attach. The map panel uses this to
    /// bind/rebind when a world loads.
    func mapperAttachments() -> AsyncStream<Mapper> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Mapper>.makeStream(bufferingPolicy: .bufferingNewest(1))
        mapperAttachmentSubscribers[id] = continuation
        if let mapper { continuation.yield(mapper) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeMapperAttachmentSubscriber(id) }
        }
        return stream
    }

    private func removeMapperAttachmentSubscriber(_ id: UUID) {
        mapperAttachmentSubscribers[id] = nil
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
        loadedPluginsDirectory = directory
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
            // GetInfo(66)/(67) → the world-data dir (trailing slash so
            // `GetInfo(66)..WorldName()..".db"` resolves to the mapper DB).
            let worldDir = worldDataDirectory.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
            let context = PluginContext(
                pluginID: plugin.id,
                pluginName: plugin.name,
                pluginDirectory: directory.path,
                worldDirectory: worldDir,
                appDirectory: worldDir
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
        // Run while either the user's script engine or the S&D host has timers.
        guard scriptEngine != nil || searchAndDestroy != nil else {
            timerTask = nil
            return
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = await self?.nextTimerDeadline() else { return }
                let delay = deadline.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { return }
                await self?.applyDueTimers()
            }
        }
    }

    /// The earliest deadline across the user's timers and S&D's timers.
    private func nextTimerDeadline() async -> Date? {
        let engine = await scriptEngine?.nextTimerDeadline()
        let snd = await searchAndDestroy?.nextTimerDeadline()
        return [engine, snd].compactMap(\.self).min()
    }

    /// Fire the timers due at `now` and apply their effects. Factored out so
    /// tests can drive timer firing deterministically without real sleeping.
    internal func applyDueTimers(at now: Date = Date()) async {
        if let scriptEngine {
            await applyScriptEffects(scriptEngine.fireDueTimers(at: now))
            await rearmTimerLoopIfScriptScheduled()
        }
        if let searchAndDestroy {
            await applyScriptEffects(searchAndDestroy.fireTimers(at: now))
            await rearmTimerLoopIfSnDScheduled()
        }
    }

    /// Render an ANSI-SGR string into a single ``Line`` with styled runs, by
    /// running it through the ``ANSIParser`` (used by the shim's `AnsiNote`,
    /// e.g. `AnsiNote(ColoursToANSI(text))`).
    /// Build a dimmed scrollback line echoing a user-typed command.
    static func inputEchoLine(_ command: String) -> Line {
        let length = (command as NSString).length
        let runs = length > 0
            ? [StyledRun(
                utf16Range: 0..<length,
                style: StyleAttributes(foreground: .rgb(red: 140, green: 140, blue: 140))
            )]
            : []
        return Line(id: LineID(0), text: command, runs: runs)
    }

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
            // A run is needed for a non-default style *or* a hyperlink (which
            // may sit on otherwise-default text).
            if !style.isDefault || segment.link != nil, start < end {
                runs.append(StyledRun(utf16Range: start..<end, style: style, link: segment.link))
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

import Foundation

/// Applying scripting decisions (triggers/aliases) to the live session.
public extension SessionController {
    /// Whether `line` should be withheld from the main output given the
    /// blank-line preference: only *completely empty* text (matching the
    /// reference's `^$`, so a whitespace-only line is kept).
    static func omitsFromOutput(_ line: Line, omitBlankLines: Bool) -> Bool {
        omitBlankLines && line.text.isEmpty
    }

    /// True when `text` is an Aardwolf telnet-102 "tagged output" line — it
    /// begins with `{tag}` or `{/tag}` where `tag` is a lowercase identifier
    /// (ASCII letters/digits/underscore, no internal spaces): `{rname}`,
    /// `{coords}`, `{invdata}`, `{/invdata}`, `{spellheaders}`, … These are
    /// protocol markers; Aardwolf never starts player-visible prose (says/tells/
    /// channels/descriptions) with `{lowercaseword}`, so withholding them from
    /// the live window is safe. Used only as a *display* gag, applied after every
    /// plugin has processed the line — so it's non-destructive (the line stays in
    /// the recording + transcript and is still seen by triggers/plugins) and
    /// non-disruptive. dinv's `{ DINV fence N }` (leading space, uppercase) does
    /// NOT match — and is gagged by dinv itself anyway.
    static func isAardwolfTagLine(_ text: String) -> Bool {
        var rest = Substring(text)
        guard rest.first == "{" else { return false }
        rest = rest.dropFirst()
        if rest.first == "/" { rest = rest.dropFirst() }
        // The first identifier char must be a lowercase ASCII letter.
        guard let firstID = rest.first, ("a"..."z").contains(firstID) else { return false }
        rest = rest.dropFirst()
        // Identifier body, then a closing brace, ends a valid tag.
        for char in rest {
            if char == "}" { return true }
            let isBodyChar = ("a"..."z").contains(char)
                || ("0"..."9").contains(char) || char == "_"
            if !isBodyChar { return false }
        }
        return false // no closing brace → not a tag line
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
        // Host-side gag of dinv's background `wish list` probe (its own
        // omit-from-output trigger is unreliable under the live plugin set). Runs
        // *after* process()/S&D so dinv still parses the wishes from the line.
        let wishGag = consumeWishProbeGag(line)
        // Opt-in: withhold leftover Aardwolf tag lines (`{rname}`/`{coords}`/…)
        // from the live window. Tested on the OUTGOING line so a tag a plugin
        // already transformed into shown text (Rich Exits' clickable exits) is
        // never gagged; runs last so every plugin has already processed the raw
        // line (display-only — still recorded + still seen by triggers).
        let tagGag = gagTagLines && Self.isAardwolfTagLine(outLine.text)
        if !disposition.gag, !sndGag, !omitBlank, !richExitsGag, !wishGag, !tagGag {
            await scrollbackStore.append(outLine)
            // Phase-2 keyword notifications fire on lines the user actually sees.
            notifyForOutput(outLine.text)
        } else {
            // Record *why* a line was withheld (the transcript otherwise only has
            // the pre-gag RECV, so a leak/over-gag report can't be diagnosed from
            // it). Reasons aren't exclusive; list every one that fired.
            let reasons = [
                disposition.gag ? "script" : nil,
                sndGag ? "snd" : nil,
                richExitsGag ? "richexits" : nil,
                omitBlank ? "blank" : nil,
                wishGag ? "wishprobe" : nil,
                tagGag ? "tag" : nil
            ].compactMap(\.self).joined(separator: "+")
            logTranscript(.gag, "[\(reasons)] \(line.text)")
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

    /// Attach the live Search-and-Destroy host (already configured + loaded),
    /// replay the current GMCP snapshot so it's initialised (not stuck in an
    /// "unknown state" until the next `char.status`), and start its timer loop.
    /// Call when a world loads or when the host is re-created mid-session (a DB
    /// import or plugin change re-runs the world load).
    func attachSearchAndDestroy(_ host: SearchAndDestroyHost) async {
        searchAndDestroy = host
        // The connect-time state handler only fires on a transition, so a host
        // attached mid-session must be told it's connected + given the current
        // GMCP snapshot, or its first xcp sits in an "unknown state".
        if state == .connected {
            await host.setConnected(true)
            await replayGMCPSnapshot(to: host)
        }
        restartTimerLoop()
    }

    /// Replay the latest per-package GMCP snapshot into `host` so it's
    /// initialised immediately. Order: char.base/status first (tier/state),
    /// then room.info (sets current_room), then the rest — so a freshly
    /// re-attached host has a ready character + a known room right away.
    func replayGMCPSnapshot(to host: SearchAndDestroyHost) async {
        let priority = ["char.base", "char.status", "room.info"]
        let ordered = priority.filter { latestGMCPByPackage[$0] != nil }
            + latestGMCPByPackage.keys.filter { !priority.contains($0) }.sorted()
        for package in ordered {
            guard let json = latestGMCPByPackage[package] else { continue }
            await applyScriptEffects(host.applyGMCP(package: package, json: json))
        }
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
                await sendLines(command)
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

    /// Send `command` one line at a time — a multi-line alias expansion becomes
    /// separate commands (MUSHclient's per-line Send), each offered to OnPluginSend.
    private func sendLines(_ command: String) async {
        for line in Self.splitSendLines(command) {
            await sendCommandThroughPlugins(line)
        }
    }

    /// Split a send into per-line commands. No newline → unchanged. With newlines
    /// → each line, dropping one trailing empty (`"look\n"` → `look`).
    nonisolated static func splitSendLines(_ text: String) -> [String] {
        guard text.contains("\n") else { return [text] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// Send a command, first offering it to plugins' `OnPluginSend` (MUSHclient's
    /// send hook). A plugin blocking it suppresses the raw send — it handled it
    /// (dinv strips its `DINV_BYPASS` prefix + re-sends). Hook effects applied,
    /// re-entrancy-guarded. No script engine → sends straight to the MUD.
    private func sendCommandThroughPlugins(_ command: String) async {
        // While OnPluginSend is processing, a send goes straight to the MUD
        // (MUSHclient's m_bPluginProcessingSend guard) — so the bare command a
        // plugin re-sends from inside the hook (dinv's bypass) isn't re-offered
        // to the hook and re-queued.
        guard let scriptEngine, !pluginProcessingSend else {
            // A bypass re-send (dinv sending from inside OnPluginSend). dinv's
            // background `wish list` probe travels this path; arm the host-side
            // gag of its output (a user typing `wish list` has
            // pluginProcessingSend false and is never gagged).
            armWishProbeGagIfNeeded(command)
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
            checkQuestReady(json) // phase-3 quest-ready notification (S&D model edge)
        case .httpRequest(let request):
            performHTTPRequest(request)
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
    /// broadcast it sees *while the character is active*. Loaded at connect time,
    /// the `char.base` arriving during login (state ≠ active) would latch its
    /// "GMCP initialized" flag and init never runs — so we record the state dir
    /// and load on the first active `char.status` (see ``loadPendingDinv``).
    func armBundledDinv(stateDirectory: String) {
        pendingDinvStateDirectory = stateDirectory
    }

    /// dinv's background `wish list` probe marker — its output (a header, the
    /// owned/unowned rows, totals) is bracketed by this echoed fence.
    private static let wishProbeFence = "DINV wish list fence"

    /// Arm the host-side gag of dinv's `wish list` probe output when dinv sends
    /// the probe (recognised on its bypass path). The cap bounds the gag so a
    /// missing fence can't swallow output forever — Aardwolf's full wish list is
    /// ~35 rows; 80 is generous headroom.
    func armWishProbeGagIfNeeded(_ command: String) {
        if command == "wish list" { wishProbeGagLinesRemaining = 80 }
    }

    /// Whether `line` is part of dinv's in-flight `wish list` probe and should be
    /// withheld. Decrements the safety cap and clears the gag once dinv's fence
    /// marker arrives (that fence line is itself gagged).
    func consumeWishProbeGag(_ line: Line) -> Bool {
        guard wishProbeGagLinesRemaining > 0 else { return false }
        wishProbeGagLinesRemaining -= 1
        if line.text.contains(Self.wishProbeFence) { wishProbeGagLinesRemaining = 0 }
        return true
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

    /// Attach the lsqlite3 sandbox root (the `~/Documents/Proteles` tree), so
    /// plugins can open SQLite files anywhere under it — their own per-character
    /// data dirs and the global `Databases/` — but nothing outside. Call when a
    /// world loads. (Per-plugin `GetInfo(66)` is set in the loader.)
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

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
    /// begins with `{tag}`/`{/tag}` (lowercase identifier, optional ` args`
    /// before the brace): `{rname}…`, `{coords}…`, `{spellheaders hsp}`, …
    /// Aardwolf never starts player-visible prose with `{lowercaseword}`,
    /// and dinv's `{ DINV fence N }` (leading space, uppercase) does NOT
    /// match. The grammar + the display transform live in ``AardwolfTags``.
    static func isAardwolfTagLine(_ text: String) -> Bool {
        AardwolfTags.leadingTag(in: text) != nil
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
        // Opt-in: clean Aardwolf tag markers from the live window — strip the
        // leading `{rname}`-style marker and show the content; hide the line
        // entirely only for machine-data tags ({coords}, {invmon}, …) or when
        // nothing but the marker remains ({roomobjs}). Tested on the OUTGOING
        // line so a tag a plugin already transformed into shown text (Rich
        // Exits' clickable exits) is never touched; runs last so every plugin
        // has already processed the raw line (display-only — still recorded +
        // still seen by triggers).
        var displayLine = outLine
        var tagGag = false
        if gagTagLines, Self.isAardwolfTagLine(outLine.text) {
            if let stripped = AardwolfTags.displayLine(for: outLine) {
                displayLine = stripped
            } else {
                tagGag = true
            }
        }
        if !disposition.gag, !sndGag, !omitBlank, !richExitsGag, !wishGag, !tagGag {
            await scrollbackStore.append(displayLine)
            // Phase-2 keyword notifications fire on lines the user actually sees.
            notifyForOutput(displayLine.text)
            // TTS (#9) speaks displayed lines only — gagged spam never talks.
            speakForOutput(displayLine.text)
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

    /// If a plugin's `AddTimer`/`DoAfter` (e.g. via the `wait` helper)
    /// scheduled a one-shot, restart the timer loop so it fires even if the
    /// loop was idle (it exits when no timers remain).
    internal func rearmTimerLoopIfScriptScheduled() async {
        if await scriptEngine?.takeDidScheduleTimer() == true {
            restartTimerLoop()
        }
    }

    /// Print a system note to the main output (used by UI flows like database
    /// import to report results where the user is actually looking, mirroring
    /// how the reference mapper prints its Notes to the output).
    func echoSystemNote(_ text: String) async {
        await applyScriptEffects([.note(text: text, foreground: "cyan", background: nil)])
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
        if await applyStoreEffect(effect) { return }
        if applySpeechEffect(effect) { return }
        if await applyAudioEffect(effect) { return }
        switch effect {
        case .setAutomationsSuspended(let suspended):
            await scriptEngine?.setSuspended(suspended)
        case .persistPluginState(let id):
            await persistNativePluginState(id: id)
        case .aardwolfTelnet(let option, let on):
            try? await sendRaw(Self.aardwolfTelnetBytes(option: option, on: on))
        case .mapperCall(let function, let args):
            await applyMapperCall(function: function, args: args)
        case .publishModel(let json):
            publishedModelsContinuation.yield(json)
        case .httpRequest(let request):
            performHTTPRequest(request)
        default:
            await applyInboundControlEffect(effect)
        }
    }

    /// The audio effects (sound cues + chat review — the review needs the
    /// async ChatStore, so it can't live in the sync speech handler).
    /// Returns true when handled.
    private func applyAudioEffect(_ effect: ScriptEffect) async -> Bool {
        switch effect {
        case .playSound(let file, let volume, let pan):
            // The soundpack's mute gates every cue source (its own events
            // already self-gate; this catches S&D's direct PlaySound and
            // shim plugins) — except the soundpack's own settings-change
            // confirmation, which it orders BEFORE the mute flag flips.
            if !soundCuesMuted {
                soundCuesContinuation.yield(SoundCue(file: file, volume: volume, pan: pan))
            }
        case .setSoundCuesMuted(let muted):
            soundCuesMuted = muted
        case .speakChatReview(let channel, let count):
            await speakChatReview(channel: channel, count: count)
        default:
            return false
        }
        return true
    }

    /// Effects that just feed a UI store (the captured maps, the tick anchor,
    /// the Lua Console). Returns true when handled.
    private func applyStoreEffect(_ effect: ScriptEffect) async -> Bool {
        switch effect {
        case .updateMap(let map):
            await mapStore.update(map)
        case .updateBigmap(let zone, let name, let lines):
            await bigmapStore.update(BigmapStore.ContinentMap(zone: zone, name: name, lines: lines))
        case .diagnostic(let source, let message):
            // Tee to the Lua Console window — and ALWAYS to the transcript
            // (#63): with #16 routing errors console-only, the red note never
            // exists, the console dies with the session, and a post-mortem
            // transcript had no record that a script failed.
            logTranscript(.note, "[script-error\(source.map { ": \($0)" } ?? "")] \(message)")
            await scriptDiagnostics.append(ScriptDiagnostic(
                severity: .error, source: source, message: message
            ))
        case .updateTick(let date):
            await gmcpState.setLastTick(date)
        default:
            return false
        }
        return true
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

    // MARK: - Script set

    /// Replace the live script set (triggers/aliases/timers) with
    /// `document`'s and restart the timer loop. Called when the active world
    /// changes. No-op without a script engine.
    func loadScripts(_ document: ScriptDocument) async {
        guard let scriptEngine else { return }
        await scriptEngine.reload(document)
        // The mapper / S&D bridges re-assert on (re-)attach later in the world
        // load; reset here so a feature disabled this load (D-107) stops
        // answering IsPluginInstalled.
        await scriptEngine.setBridgedPlugin(SearchAndDestroyHost.pluginID, installed: false)
        await scriptEngine.setBridgedPlugin(Self.mapperBridgePluginID, installed: false)
        restartTimerLoop()
    }

    /// Attach a per-world variable store and hydrate the engine's scoped
    /// variables from it. Call on connect, before loading plugins (so their
    /// `OnPluginInstall` reads persisted values). The store is then written
    /// through as variables change.
    func attachVariableStore(_ store: VariableStore) async {
        variableStore = store
        try? await store.load()
        // The S&D host hydrates separately (its own runtime, before its
        // load — see hydrateSearchAndDestroyVariables), so the store
        // attaches even with no script engine (#52).
        if let scriptEngine {
            await scriptEngine.loadVariables(store.scopes)
        }
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
    /// The MUSHclient mapper plugin id the shim's IsPluginInstalled bridge
    /// answers for when the native mapper is attached.
    static let mapperBridgePluginID = "b6eae87ccedd84f510b74714"

    func attachMapper(_ mapper: Mapper) {
        self.mapper = mapper
        Task { [scriptEngine] in
            await scriptEngine?.setBridgedPlugin(Self.mapperBridgePluginID, installed: true)
        }
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
    /// attached store — from the script engine AND the S&D host (its own
    /// runtime, invisible to the engine — #52). Cheap when nothing changed
    /// (no I/O). Called after each batch of script execution so plugin
    /// variables survive relaunches.
    func persistVariablesIfDirty() async {
        guard let variableStore else { return }
        if let scriptEngine {
            await persistDirtyScopes(
                dirty: scriptEngine.takeDirtyVariableScopes(),
                snapshot: { await scriptEngine.variablesSnapshot() },
                into: variableStore
            )
        }
        if let searchAndDestroy {
            await persistDirtyScopes(
                dirty: searchAndDestroy.takeDirtyVariableScopes(),
                snapshot: { await searchAndDestroy.variablesSnapshot() },
                into: variableStore
            )
        }
    }

    /// Write one runtime's dirty scopes to the store (snapshot lazily — most
    /// calls have nothing dirty).
    private func persistDirtyScopes(
        dirty: Set<String>,
        snapshot: () async -> [String: [String: String]],
        into store: VariableStore
    ) async {
        guard !dirty.isEmpty else { return }
        let all = await snapshot()
        for scope in dirty {
            try? await store.update(scope: scope, variables: all[scope] ?? [:])
        }
    }

    /// Hydrate the S&D host's persisted variables (its runtime is separate
    /// from the script engine's, so ``attachVariableStore(_:)`` can't reach
    /// it). Call BEFORE ``SearchAndDestroyHost/load()`` — S&D reads
    /// `GetVariable` at script top-level (the `xset` flags, area ranges), so
    /// hydrating after load is too late (#52).
    func hydrateSearchAndDestroyVariables(_ host: SearchAndDestroyHost) async {
        guard let variableStore else { return }
        let scope = SearchAndDestroyHost.pluginID
        await host.hydrateVariables(variableStore.scopes[scope] ?? [:])
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

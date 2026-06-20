import Foundation

/// Small helpers used by the `proteles.*` host-function dispatch: reading
/// typed arguments out of the marshalled `[LuaValue]`, and projecting a
/// resolved ``PluginContext/InfoValue`` (for `proteles.info`) to a Lua value.
/// Factored out of `LuaRuntime` to keep that file within the length budget.
extension LuaRuntime {
    /// Pop the error object at the top of the stack as a String.
    func popError() -> String {
        Self.popMessage(state)
    }

    /// Read-only `proteles.*` queries that return a value (rather than
    /// recording an effect): `info`, `pluginID`, `isConnected`.
    nonisolated func queryValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .info: [infoValue(arguments)]
        case .pluginID: [.string(pluginContext.pluginID)]
        case .isConnected: [.boolean(connected)]
        case .fileExists, .makeDirectory, .readFile, .writeFile: fileValue(function, arguments)
        case .dialog: [dialogValue(arguments)]
        case .colourNameToRGB, .rgbColourToName, .adjustColour: colourValue(function, arguments)
        case .lineCount, .linesInBuffer, .lineInfo, .styleInfo, .recentLines:
            bufferValue(function, arguments)
        case .clipboardGet, .clipboardSet: clipboardValue(function, arguments)
        case .sqliteAllowed, .mapperMergeSQL, .monotonic, .databaseDir, .isPluginInstalled,
             .createGUID, .uniqueID:
            miscValue(function, arguments)
        // Trigger/alias/timer introspection (LuaRuntime+AutomationInfo.swift) —
        // routed via the default so this switch gains no new branch.
        default: automationValue(function, arguments)
        }
    }

    /// The grab-bag of small scalar queries, split from ``queryValue`` for
    /// its complexity budget. `isPluginInstalled` answers true for a loaded
    /// shim plugin or a natively-bridged id (mapper / S&D / GMCP / chat).
    nonisolated func miscValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .sqliteAllowed: [.boolean(sqliteAllows(Self.argString(arguments, 0)))]
        case .mapperMergeSQL:
            { let merge = mapperMergeSQL(Self.argString(arguments, 0))
                return [.string(merge.overlay), .string(merge.sql)] }()
        case .monotonic: [.number(Self.monotonicSeconds())]
        case .databaseDir: [.string(databasesDirectory)]
        case .isPluginInstalled:
            [.boolean({
                let id = Self.argString(arguments, 0)
                return pluginEnvs[id] != nil || bridgedPluginIDs.contains(id)
            }())]
        case .createGUID: [.string(ScriptIdentifiers.createGUID())]
        case .uniqueID: [.string(ScriptIdentifiers.uniqueID())]
        default: []
        }
    }

    /// The MUSHclient colour helpers, all pure ``MUSHColour`` math:
    /// `ColourNameToRGB`/`RGBColourToName` (name ↔ COLORREF) and `AdjustColour`
    /// (invert / lighten / darken / de- or re-saturate via HLS).
    nonisolated func colourValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .colourNameToRGB: [.number(Double(MUSHColour.colourNameToRGB(Self.argString(arguments, 0))))]
        case .rgbColourToName: [.string(MUSHColour.rgbColourToName(Int(Self.argDouble(arguments, 0))))]
        case .adjustColour:
            [.number(Double(MUSHColour.adjustColour(
                Int(Self.argDouble(arguments, 0)), method: Int(Self.argDouble(arguments, 1))
            )))]
        default: []
        }
    }

    /// The instant `proteles.monotonic()` counts from (first use). Only
    /// deltas are meaningful — consumers (S&D's `os.clock` shim, the shim's
    /// `utils.timer`) subtract successive readings for debounces, so the
    /// absolute value is deliberately small and process-relative.
    private static let monotonicBase = ContinuousClock.now

    /// Seconds since ``monotonicBase`` on a clock that never steps. The old
    /// `Date().timeIntervalSince1970` was wall-clock: an NTP adjustment could
    /// jump it backwards and confuse S&D's 1-second debounces (#58).
    nonisolated static func monotonicSeconds() -> Double {
        let elapsed = monotonicBase.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// `proteles.clipboardGet()` → the app clipboard provider's current string
    /// (or "" with no provider); `proteles.clipboardSet(text)` writes it and
    /// returns nothing. Split from ``queryValue`` because the set path has a
    /// side effect (the query switch is an expression).
    nonisolated func clipboardValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .clipboardSet:
            clipboardProvider?.set(Self.argString(arguments, 0))
            return []
        default:
            return [.string(clipboardProvider?.get() ?? "")]
        }
    }

    /// The sandbox-gated filesystem host calls (`fileExists`/`makeDirectory`/
    /// `readFile`/`writeFile`), split out so ``queryValue`` stays within the
    /// complexity budget.
    nonisolated func fileValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .fileExists: [.boolean(fileExistsAllowed(Self.argString(arguments, 0)))]
        case .makeDirectory: [.boolean(makeDirectoryAllowed(Self.argString(arguments, 0)))]
        case .readFile: [readFileContents(Self.argString(arguments, 0)).map { LuaValue.string($0) } ?? .nil]
        case .writeFile:
            [.boolean(writeFileAllowed(Self.argString(arguments, 0), Self.argString(arguments, 1)))]
        default: []
        }
    }

    /// `proteles.info(code)` → the resolved value as a Lua value, or `nil`
    /// for an unimplemented code.
    nonisolated func infoValue(_ arguments: [LuaValue]) -> LuaValue {
        guard let code = arguments.first?.numberValue.map({ Int($0) }) else { return .nil }
        // Output-window client geometry (#30) — answered live from the real
        // output-view size, not a per-plugin constant: 280 = client height,
        // 281 = client width (MUSHclient's GetClientRect bottom / right).
        if code == 280 { return .number(Double(outputPixelHeight)) }
        if code == 281 { return .number(Double(outputPixelWidth)) }
        guard let value = pluginContext.info(code) else { return .nil }
        switch value {
        case .text(let text): return .string(text)
        case .number(let number): return .number(number)
        case .flag(let flag): return .boolean(flag)
        }
    }

    /// Push the live output-view pixel size, surfaced via `GetInfo(280/281)`
    /// (#30). Called from the app as the output view resizes.
    func setOutputGeometry(width: Int, height: Int) {
        outputPixelWidth = max(0, width)
        outputPixelHeight = max(0, height)
    }

    /// Append one displayed line to the output-buffer mirror (``OutputLineBuffer``)
    /// that backs `GetLineCount`/`GetLineInfo`/… Pushed per line by
    /// `SessionController` after gag resolution.
    func recordOutputLine(
        id: UInt64, timestamp: Date, text: String, runs: [StyledRun], kind: OutputLineKind
    ) {
        outputBuffer.append(BufferedLine(id: id, timestamp: timestamp, text: text, runs: runs, kind: kind))
    }

    /// Clear the output-buffer mirror and stamp the connect time (`GetLineCount`
    /// counts from connect; infotype 13 is elapsed-since-connect).
    func resetOutputBuffer(connectedAt: Date) {
        outputBuffer.reset(connectedAt: connectedAt)
    }

    /// The output-buffer host queries (`GetLineCount`/`GetLinesInBufferCount`/
    /// `GetLineInfo`/`GetStyleInfo`/`GetRecentLines`) — all synchronous reads of
    /// the runtime's ``outputBuffer`` mirror.
    nonisolated func bufferValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .lineCount: [.number(Double(outputBuffer.lineCount))]
        case .linesInBuffer: [.number(Double(outputBuffer.linesInBuffer))]
        case .lineInfo:
            [outputBuffer.lineInfo(Int(Self.argDouble(arguments, 0)), Int(Self.argDouble(arguments, 1)))]
        case .styleInfo:
            [outputBuffer.styleInfo(
                Int(Self.argDouble(arguments, 0)),
                Int(Self.argDouble(arguments, 1)),
                Int(Self.argDouble(arguments, 2))
            )]
        case .recentLines: [.string(outputBuffer.recentLines(Int(Self.argDouble(arguments, 0))))]
        default: []
        }
    }

    /// `proteles.dialog(kind, …)` → build a ``ScriptDialog``, run it through the
    /// app's provider (synchronously), and map the result to a Lua value. With no
    /// provider (headless / tests), degrades safely: "ok" for msgbox, else nil.
    nonisolated func dialogValue(_ arguments: [LuaValue]) -> LuaValue {
        let kind = Self.argString(arguments, 0)
        let request: ScriptDialog
        switch kind {
        case "msgbox":
            request = .message(
                text: Self.argString(arguments, 1),
                title: Self.argString(arguments, 2),
                buttons: Int(Self.argDouble(arguments, 3))
            )
        case "input":
            request = .input(
                prompt: Self.argString(arguments, 1),
                title: Self.argString(arguments, 2),
                defaultText: Self.argString(arguments, 3),
                multiline: Self.argBool(arguments, 4)
            )
        case "choose":
            request = .choose(
                prompt: Self.argString(arguments, 1),
                title: Self.argString(arguments, 2),
                items: arguments.dropFirst(3).map { $0.stringValue ?? "" }
            )
        case "openfile":
            request = .openFile(
                message: Self.argString(arguments, 1),
                chooseDirectory: Self.argBool(arguments, 2)
            )
        default:
            return .nil
        }
        guard let result = dialogProvider?(request) else {
            return kind == "msgbox" ? .string("ok") : .nil
        }
        switch result {
        case .button(let label): return .string(label)
        case .text(let text): return text.map(LuaValue.string) ?? .nil
        case .index(let index): return index.map { LuaValue.number(Double($0)) } ?? .nil
        case .path(let path): return path.map(LuaValue.string) ?? .nil
        }
    }

    /// `proteles.accelerator(key, send, sendto)` (MUSHclient Accelerator/
    /// AcceleratorTo) → parse the key string to a ``KeyChord`` and register it in
    /// the live MacroEngine via the app's registrar. `sendto == 12` (script) runs
    /// `send` as Lua; anything else sends it as a command. An unparseable key is
    /// ignored.
    nonisolated func registerAccelerator(_ arguments: [LuaValue]) {
        guard let registrar = acceleratorRegistrar,
              let chord = AcceleratorParser.chord(from: Self.argString(arguments, 0))
        else { return }
        let send = Self.argString(arguments, 1)
        let action: MacroAction = Int(Self.argDouble(arguments, 2)) == 12 ? .script(send) : .command(send)
        registrar(Macro(name: "Accelerator", chord: chord, action: action))
    }

    static func argString(_ arguments: [LuaValue], _ index: Int) -> String {
        index < arguments.count ? (arguments[index].stringValue ?? "") : ""
    }

    static func argOptionalString(_ arguments: [LuaValue], _ index: Int) -> String? {
        index < arguments.count ? arguments[index].stringValue : nil
    }

    static func argFunctionRef(_ arguments: [LuaValue], _ index: Int) -> Int32? {
        guard index < arguments.count, case .functionRef(let ref) = arguments[index] else {
            return nil
        }
        return ref
    }

    /// Route an effect-recording host call to the right recorder (mapper
    /// calls have a distinct shape; everything else is an inert output effect).
    nonisolated func recordEffect(_ function: HostFunction, _ arguments: [LuaValue]) {
        if recordSpecialCall(function, arguments) { return }
        if recordControlEffect(function, arguments) { return }
        switch function {
        case .aardwolfTelnet:
            effects.append(.aardwolfTelnet(
                option: Int(Self.argDouble(arguments, 0)),
                on: Self.argBool(arguments, 1)
            ))
        case .enableTrigger, .enableTimer, .enableAlias, .enableGroup:
            effects.append(Self.enableEffect(function, arguments))
        case .doAfter:
            effects.append(.scheduleAfter(
                seconds: Self.argDouble(arguments, 0),
                isScript: Self.argBool(arguments, 2),
                body: Self.argString(arguments, 1)
            ))
        case .addTrigger, .addAlias:
            effects.append(Self.addAutomationEffect(function, arguments))
        case .notify:
            effects.append(.notify(
                title: Self.argString(arguments, 0),
                body: Self.argString(arguments, 1)
            ))
        case .speak:
            // proteles.speak(text[, interrupt]) — plugin TTS (#9, the
            // ttsSpeak analog); spoken whenever the user has TTS enabled.
            effects.append(.speak(
                text: Self.argString(arguments, 0),
                interrupt: Self.argBool(arguments, 1)
            ))
        default: recordOutputEffect(function, arguments)
        }
    }

    /// The non-automation "special" host calls (mapper/chat/publish bridges +
    /// the method-dispatch accelerator/HTTP). Split out so ``recordEffect``
    /// stays within the complexity budget. Returns whether it handled `function`.
    private nonisolated func recordSpecialCall(_ function: HostFunction, _ arguments: [LuaValue]) -> Bool {
        switch function {
        case .mapperCall: recordMapperCall(arguments)
        case .chatCapture:
            effects.append(.chatCapture(
                text: Self.argString(arguments, 0),
                channel: Self.argOptionalString(arguments, 1) ?? ""
            ))
        case .publish: effects.append(.publishModel(Self.argString(arguments, 0)))
        case .playSound:
            // MUSHclient `PlaySound` units: volume in dB (0 = full; out of
            // range coerces to full), pan −100…100. Converted here so the
            // effect carries player-ready linear gain (#10).
            effects.append(.playSound(
                file: Self.argString(arguments, 0),
                volume: SoundVolume.playSoundGain(volumeDb: Self.argDouble(arguments, 1)),
                pan: SoundVolume.playSoundPan(mushPan: Self.argDouble(arguments, 2))
            ))
        case .sndCall:
            effects.append(.callSearchAndDestroy(
                function: Self.argString(arguments, 0),
                args: arguments.dropFirst().map { $0.stringValue ?? "" }
            ))
        case .accelerator: registerAccelerator(arguments)
        case .http: registerHTTPRequest(arguments)
        case .button:
            if let command = Self.buttonCommand(arguments) { effects.append(.button(command)) }
        default: return false
        }
        return true
    }

    /// The trigger/alias group + option control calls (`SetTriggerOption`/
    /// `SetTriggerGroup`/`SetAliasOption`), the Tier-2 `StopEvaluatingTriggers`,
    /// and `TraceOut`/`SetStatus`. Split from ``recordEffect`` for its
    /// complexity budget. Returns whether it handled `function`.
    private nonisolated func recordControlEffect(
        _ function: HostFunction, _ arguments: [LuaValue]
    ) -> Bool {
        switch function {
        case .setTriggerGroup:
            effects.append(.setTriggerGroup(
                name: Self.argString(arguments, 0),
                group: Self.argString(arguments, 1)
            ))
        case .setTriggerOption:
            effects.append(.setTriggerOption(
                name: Self.argString(arguments, 0),
                option: Self.argString(arguments, 1),
                value: Self.argString(arguments, 2)
            ))
        case .setAliasOption:
            effects.append(.setAliasOption(
                name: Self.argString(arguments, 0),
                option: Self.argString(arguments, 1),
                value: Self.argString(arguments, 2)
            ))
        case .stopEvaluatingTriggers:
            effects.append(.stopEvaluatingTriggers(allPlugins: Self.argBool(arguments, 0)))
        case .trace:
            effects.append(.trace(Self.argString(arguments, 0)))
        default: return false
        }
        return true
    }

    /// Map an `AddTriggerEx`/`AddAlias` host call to its effect (extracted so
    /// ``recordEffect`` stays within the complexity budget).
    private nonisolated static func addAutomationEffect(
        _ function: HostFunction, _ arguments: [LuaValue]
    ) -> ScriptEffect {
        let name = argString(arguments, 0)
        let pattern = argString(arguments, 1)
        let flags = Int(argDouble(arguments, 2))
        let script = argString(arguments, 3)
        // Trigger sequence (arg 4); absent for AddAlias and bare AddTrigger.
        // MUSHclient's default is 100. dinv passes 0 for its wish-capture trigger
        // so it evaluates before any pre-empting stop-on-match trigger.
        let sequence = arguments.count > 4 ? Int(argDouble(arguments, 4)) : 100
        return function == .addAlias
            ? .addAlias(name: name, pattern: pattern, flags: flags, script: script)
            : .addTrigger(name: name, pattern: pattern, flags: flags, script: script, sequence: sequence)
    }

    /// Map an `enable*(name, on)` host call to its effect (collapsed so
    /// ``recordEffect`` stays within the complexity budget).
    private nonisolated static func enableEffect(
        _ function: HostFunction, _ arguments: [LuaValue]
    ) -> ScriptEffect {
        let name = argString(arguments, 0)
        let on = argBool(arguments, 1)
        switch function {
        case .enableTimer: return .enableTimer(name: name, on: on)
        case .enableAlias: return .enableAlias(name: name, on: on)
        case .enableGroup: return .enableGroup(name: name, on: on)
        default: return .enableTrigger(name: name, on: on)
        }
    }

    /// Parse `proteles.button(verb, …)` (the #15 scripting API) into a
    /// ``ButtonCommand``. Verbs: add(group,label,command),
    /// toggle(group,label,on,off), state(label, "1"/"0"/true), remove(label).
    nonisolated static func buttonCommand(_ arguments: [LuaValue]) -> ButtonCommand? {
        switch argString(arguments, 0).lowercased() {
        case "add":
            return .add(
                group: argString(arguments, 1),
                label: argString(arguments, 2),
                command: argString(arguments, 3)
            )
        case "toggle":
            return .toggle(
                group: argString(arguments, 1),
                label: argString(arguments, 2),
                on: argString(arguments, 3),
                off: argString(arguments, 4)
            )
        case "state":
            let raw = argString(arguments, 2).lowercased()
            let on = argBool(arguments, 2) || raw == "1" || raw == "on" || raw == "true"
            return .setState(label: argString(arguments, 1), on: on)
        case "remove":
            return .remove(label: argString(arguments, 1))
        default:
            return nil
        }
    }

    /// A Lua boolean argument (the curated bindings normalise truthy/falsy to
    /// a real boolean before the call), defaulting to `false`.
    nonisolated static func argBool(_ arguments: [LuaValue], _ index: Int) -> Bool {
        guard index < arguments.count else { return false }
        return arguments[index].booleanValue ?? false
    }

    /// A Lua number argument, defaulting to 0.
    nonisolated static func argDouble(_ arguments: [LuaValue], _ index: Int) -> Double {
        guard index < arguments.count else { return 0 }
        return arguments[index].numberValue ?? 0
    }

    /// Host functions whose effect is just `Effect(firstStringArg)` — folded
    /// into one lookup so the output dispatch stays within the complexity budget.
    private nonisolated(unsafe) static let singleStringEffects: [HostFunction: (String) -> ScriptEffect] = [
        .send: ScriptEffect.send, .sendNoEcho: ScriptEffect.sendNoEcho,
        .execute: ScriptEffect.execute, .echo: ScriptEffect.echo,
        .sendGMCP: ScriptEffect.sendGMCP, .echoAard: ScriptEffect.echoAard,
        .echoAnsi: ScriptEffect.echoAnsi, .simulate: ScriptEffect.simulate,
        .removeTrigger: ScriptEffect.removeTrigger,
        .reloadPlugin: { ScriptEffect.reloadPlugin(id: $0) },
        .resetTimer: { ScriptEffect.resetTimer(name: $0) }
    ]

    /// Record an inert output effect (`send`/`echo`/`note`/`colourNote`/…)
    /// for the host to apply after the chunk returns.
    nonisolated func recordOutputEffect(_ function: HostFunction, _ arguments: [LuaValue]) {
        if let make = Self.singleStringEffects[function] {
            effects.append(make(Self.argString(arguments, 0)))
            return
        }
        switch function {
        case .note: effects.append(.note(
                text: Self.argString(arguments, 0),
                foreground: Self.argOptionalString(arguments, 1),
                background: Self.argOptionalString(arguments, 2)
            ))
        case .colourNote: effects.append(.colourNote(Self.noteSegments(arguments)))
        case .hyperlink:
            // proteles.hyperlink(text, action, hint?) → a one-segment clickable
            // line. The action string is interpreted like MUSHclient's
            // Hyperlink (URL → open, else send as a command).
            effects.append(.colourNote([NoteSegment(
                text: Self.argString(arguments, 0),
                link: LineLink(
                    actionString: Self.argString(arguments, 1),
                    hint: Self.argOptionalString(arguments, 2)
                )
            )]))
        default: break
        }
    }

    /// Record a `proteles.mapperCall(fn, args…)` effect: arg0 is the function
    /// name, the rest are string arguments forwarded to the native mapper.
    nonisolated func recordMapperCall(_ arguments: [LuaValue]) {
        effects.append(.mapperCall(
            function: Self.argString(arguments, 0),
            args: arguments.dropFirst().map { $0.stringValue ?? "" }
        ))
    }

    /// Build `ColourNote` segments from its variadic `(fore, back, text)`
    /// triples. An empty colour string means "default" → `nil`. Trailing
    /// partial triples (missing text) are ignored, matching MUSHclient.
    nonisolated static func noteSegments(_ arguments: [LuaValue]) -> [NoteSegment] {
        var segments: [NoteSegment] = []
        var index = 0
        while index + 3 <= arguments.count {
            let fore = nonEmpty(arguments[index].stringValue)
            let back = nonEmpty(arguments[index + 1].stringValue)
            let text = arguments[index + 2].stringValue ?? ""
            segments.append(NoteSegment(text: text, foreground: fore, background: back))
            index += 3
        }
        return segments
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

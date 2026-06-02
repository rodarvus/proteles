import Foundation

/// Small helpers used by the `proteles.*` host-function dispatch: reading
/// typed arguments out of the marshalled `[LuaValue]`, and projecting a
/// resolved ``PluginContext/InfoValue`` (for `proteles.info`) to a Lua value.
/// Factored out of `LuaRuntime` to keep that file within the length budget.
extension LuaRuntime {
    /// Read-only `proteles.*` queries that return a value (rather than
    /// recording an effect): `info`, `pluginID`, `isConnected`.
    nonisolated func queryValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .info: [infoValue(arguments)]
        case .pluginID: [.string(pluginContext.pluginID)]
        case .isConnected: [.boolean(connected)]
        case .sqliteAllowed: [.boolean(sqliteAllows(Self.argString(arguments, 0)))]
        case .monotonic: [.number(Date().timeIntervalSince1970)]
        case .fileExists, .makeDirectory, .readFile, .writeFile: fileValue(function, arguments)
        case .dialog: [dialogValue(arguments)]
        case .clipboardGet, .clipboardSet: clipboardValue(function, arguments)
        default: []
        }
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
        guard let code = arguments.first?.numberValue.map({ Int($0) }),
              let value = pluginContext.info(code)
        else {
            return .nil
        }
        switch value {
        case .text(let text): return .string(text)
        case .number(let number): return .number(number)
        case .flag(let flag): return .boolean(flag)
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
        case .setTriggerGroup:
            effects.append(.setTriggerGroup(
                name: Self.argString(arguments, 0),
                group: Self.argString(arguments, 1)
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
        case .accelerator: registerAccelerator(arguments)
        case .http: registerHTTPRequest(arguments)
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
        .reloadPlugin: { ScriptEffect.reloadPlugin(id: $0) }
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

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
        switch function {
        case .mapperCall: recordMapperCall(arguments)
        case .publish: effects.append(.publishModel(Self.argString(arguments, 0)))
        case .enableTrigger:
            effects.append(.enableTrigger(name: Self.argString(arguments, 0), on: Self.argBool(arguments, 1)))
        case .enableTimer:
            effects.append(.enableTimer(name: Self.argString(arguments, 0), on: Self.argBool(arguments, 1)))
        case .enableAlias:
            effects.append(.enableAlias(name: Self.argString(arguments, 0), on: Self.argBool(arguments, 1)))
        case .enableGroup:
            effects.append(.enableGroup(name: Self.argString(arguments, 0), on: Self.argBool(arguments, 1)))
        case .doAfter:
            effects.append(.scheduleAfter(
                seconds: Self.argDouble(arguments, 0),
                isScript: Self.argBool(arguments, 2),
                body: Self.argString(arguments, 1)
            ))
        case .addTrigger:
            effects.append(.addTrigger(
                name: Self.argString(arguments, 0),
                pattern: Self.argString(arguments, 1),
                flags: Int(Self.argDouble(arguments, 2)),
                script: Self.argString(arguments, 3)
            ))
        case .addAlias:
            effects.append(.addAlias(
                name: Self.argString(arguments, 0),
                pattern: Self.argString(arguments, 1),
                flags: Int(Self.argDouble(arguments, 2)),
                script: Self.argString(arguments, 3)
            ))
        case .setTriggerGroup:
            effects.append(.setTriggerGroup(
                name: Self.argString(arguments, 0),
                group: Self.argString(arguments, 1)
            ))
        default: recordOutputEffect(function, arguments)
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
        .removeTrigger: ScriptEffect.removeTrigger
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

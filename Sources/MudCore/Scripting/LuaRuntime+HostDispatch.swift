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
}

import Foundation

extension LuaRuntime {
    nonisolated func recordCommandChromeEffect(
        _ function: HostFunction,
        _ arguments: [LuaValue]
    ) -> Bool {
        switch function {
        case .deleteLines:
            let count = max(0, Int(Self.argDouble(arguments, 0)))
            outputBuffer.deleteLast(count)
            effects.append(.deleteOutputLines(count: count))
        case .setCommandInput:
            effects.append(.commandInput(CommandInputEdit(kind: .set, text: Self.argString(arguments, 0))))
        case .pasteCommandInput:
            effects.append(.commandInput(CommandInputEdit(kind: .paste, text: Self.argString(arguments, 0))))
        case .setCommandSelection:
            effects.append(.commandInput(CommandInputEdit(
                kind: .select,
                text: "",
                startColumn: Int(Self.argDouble(arguments, 0)),
                endColumn: Int(Self.argDouble(arguments, 1))
            )))
        default:
            return false
        }
        return true
    }
}

import Foundation

/// `/lua …` console command (#41): run a one-off Lua statement/expression on the
/// live script engine and echo the result/errors, instead of sending to the MUD.
/// Gated behind the explicit `/lua ` prefix so it never clutters normal input.
extension SessionController {
    /// The Lua source for a `/lua …` command (case-insensitive prefix), or `nil`
    /// if `command` isn't one. `/lua` alone yields `""` (a usage hint).
    static func luaConsoleCode(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower == "/lua" || lower.hasPrefix("/lua ") else { return nil }
        return String(trimmed.dropFirst("/lua".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Evaluate console Lua and apply its effects (echo output + result/errors).
    func runLuaConsole(_ code: String) async {
        guard let scriptEngine else {
            await applyScriptEffects([
                .note(text: "lua: scripting is unavailable", foreground: "red", background: nil)
            ])
            return
        }
        await applyScriptEffects(scriptEngine.evaluateConsole(code))
        await persistVariablesIfDirty()
        // Console code may schedule a one-shot timer (e.g. wait.make/DoAfter);
        // re-arm the idle timer loop so it actually fires (mirrors typed input).
        await rearmTimerLoopIfScriptScheduled()
    }
}

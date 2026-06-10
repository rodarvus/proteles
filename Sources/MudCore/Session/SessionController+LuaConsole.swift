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

    /// Evaluate Lua typed into the **Lua Console window**: the input echoes
    /// into the console transcript, `print`/`Note`/result output is routed to
    /// the console (NOT the scrollback), and every other effect (sends,
    /// timers, …) applies normally. `environment` picks a loaded plugin's
    /// sandbox env (nil = the user environment, like `/lua`).
    public func runLuaConsoleWindow(_ code: String, environment: String?) async {
        await scriptDiagnostics.append(ScriptDiagnostic(
            severity: .input, source: environment, message: code
        ))
        guard let scriptEngine else {
            await scriptDiagnostics.append(ScriptDiagnostic(
                severity: .error, source: nil, message: "scripting is unavailable"
            ))
            return
        }
        let effects = await scriptEngine.evaluateConsole(code, inPlugin: environment)
        var passthrough: [ScriptEffect] = []
        for effect in effects {
            switch effect {
            case .note(let text, let foreground, _):
                await scriptDiagnostics.append(ScriptDiagnostic(
                    severity: foreground == "red" ? .error : .output,
                    source: environment,
                    message: Self.strippedConsolePrefix(text)
                ))
            case .echo(let text):
                await scriptDiagnostics.append(ScriptDiagnostic(
                    severity: .output, source: environment, message: text
                ))
            default:
                passthrough.append(effect)
            }
        }
        await applyScriptEffects(passthrough)
        await persistVariablesIfDirty()
        await rearmTimerLoopIfScriptScheduled()
    }

    /// Console notes arrive prefixed `lua: ` (for scrollback identification);
    /// inside the console window that's noise.
    static func strippedConsolePrefix(_ text: String) -> String {
        text.hasPrefix("lua: ") ? String(text.dropFirst(5)) : text
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

import Foundation

public extension SessionController {
    /// A multi-line command body, split into the lines to send — MUSHclient
    /// Send-box semantics: each non-blank line goes through the input
    /// pipeline separately (`;`-stacking then applies per line). Pure.
    static func commandLines(_ body: String) -> [String] {
        // "\r\n" is a single Character (one grapheme cluster) — match it
        // explicitly or CRLF bodies don't split.
        body.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Fire a macro's action. A `.send` goes straight to the MUD (raw, no
    /// alias/mapper/S&D re-processing — an alias's "Send to MUD"); a `.command`
    /// runs through the same input pipeline as typed text (so aliases +
    /// `;`-stacking apply — an alias's "Re-process as input"); both split a
    /// multi-line body into separate commands. A `.script` runs as Lua in the
    /// user script environment and its effects are applied.
    func fire(_ action: MacroAction) async {
        switch action {
        case .send(let command):
            // Raw send, via the .send effect so multi-line + `;`-stacking (and
            // OnPluginSend) apply exactly as for an alias's .world target.
            await applyScriptEffects([.send(command)])
        case .command(let command):
            // Each line runs through the input pipeline in order — but if a line
            // is `mapper goto …`, the remaining lines wait for arrival rather
            // than racing the walk (the F9/F10/F11 `goto X` ⏎ `quest …` case).
            await sendWalkAwareBatch(Self.commandLines(command))
        case .script(let script):
            guard let scriptEngine else { return }
            await applyScriptEffects(scriptEngine.run(script))
            await persistVariablesIfDirty()
            await rearmTimerLoopIfScriptScheduled()
        case .replaceInput:
            // Sets the command line, which only the input field can do — handled
            // on the key path (see CommandInputView). No-op when fired
            // programmatically (e.g. a command-button), where there's no input.
            break
        }
    }
}

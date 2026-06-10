import Foundation

/// Typed-command dispatch: the in-app pipeline that runs before anything
/// reaches the wire (command stacking, `/lua`, native `mapper`, S&D's
/// aliases, then user aliases). Split from `SessionController.swift` for the
/// file-length budget.
extension SessionController {
    /// Route a command through the in-app pipeline (native `mapper …` → S&D →
    /// user aliases → MUD), without the user-input echo. Used by typed input and
    /// by a plugin's `Execute` (re-parsed as if typed, so S&D's
    /// `Execute("mapper goto …")` reaches the native mapper).
    func dispatchCommand(_ command: String) async throws {
        // Command stacking (Aardwolf/MUSHclient): split on `;` (`;;` = literal
        // `;`). A trailing empty piece is dropped; a lone empty line falls
        // through to dispatchSingleCommand as a bare-Enter nudge.
        let pieces = CommandStack.split(command)
        for piece in pieces {
            if piece.isEmpty, pieces.count > 1 { continue }
            try await dispatchSingleCommand(piece)
        }
    }

    /// Route one (already unstacked) command through the in-app pipeline.
    private func dispatchSingleCommand(_ command: String) async throws {
        // A bare Enter is a wire signal (prompt refresh / pager advance), not a
        // command: send it raw, bypassing mapper/S&D/alias expansion — as
        // MUSHclient's `Execute` does ("empty line - just send it"). Else a
        // loaded catch-all alias (`match="*"`/`^(.*)$`) eats the empty string.
        if command.isEmpty {
            try await sendLine(command)
            return
        }
        // Note mode (suspended automations): EVERY keystroke is note text.
        // The engine already passes input through verbatim, but the native
        // mapper and the S&D host don't observe engine suspension — so their
        // interception below would eat note lines (any line matching one of
        // S&D's ~100 aliases vanished into the hunt engine instead of the
        // note — the "can't write notes" live report). Send verbatim FIRST.
        if let scriptEngine, await scriptEngine.automationsSuspended {
            try await sendLine(command)
            return
        }
        // `/lua …` — evaluate one-off Lua on the script engine (#41), not the MUD.
        if let code = Self.luaConsoleCode(command) {
            await runLuaConsole(code)
            return
        }
        // Native `mapper …` commands are handled in-app, not sent to the MUD.
        if command.split(separator: " ").first?.lowercased() == "mapper", let mapper {
            await applyScriptEffects(mapper.handleCommand(command))
            return
        }
        // Search-and-Destroy's own commands (xcp/nx/qs/…) are intercepted by
        // its aliases before the normal path.
        if await handleSearchAndDestroyCommand(command) {
            return
        }
        if let scriptEngine {
            await applyScriptEffects(scriptEngine.expandInput(command))
            await persistVariablesIfDirty()
            // A command may schedule a one-shot (a plugin's wait.make/DoAfter
            // coroutine, e.g. dinv's build queue). The loop idles when no timers
            // remain, so re-arm it — else the resume (and its sends) never fire.
            await rearmTimerLoopIfScriptScheduled()
        } else {
            try await sendLine(command)
        }
    }
}

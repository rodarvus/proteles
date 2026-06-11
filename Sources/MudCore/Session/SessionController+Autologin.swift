import Foundation

/// Prompt-driven (Diku-style) auto-login. Extracted from
/// ``SessionController`` to keep that file within the length budget.
extension SessionController {
    struct AutologinState {
        var plan: AutologinPlan
        var phase: Phase
        /// Username re-sends after the server re-prompted for the name
        /// (stray input at the login screen restarts Aardwolf's name flow —
        /// the 2026-06-11 resume incident). Capped so a server that loops
        /// the prompt can't make us spam credentials.
        var usernameRetries = 0

        enum Phase {
            case awaitingUsername
            case awaitingPassword
            case done
        }
    }

    /// Drive the auto-login sequence. Called after each processed chunk with
    /// the lines it produced.
    ///
    /// Prompts arrive without a trailing newline, so they sit in
    /// ``LinePipeline/pendingLineText`` rather than appearing as a ``Line``.
    /// We scan both the freshly emitted lines (in case a world terminates its
    /// prompts) and the pending buffer. Credentials are sent via `sendLine`,
    /// bypassing alias expansion, quit detection, and local echo.
    func advanceAutologin(newLines: [Line]) async {
        guard var state = autologin else { return }

        switch state.phase {
        case .awaitingUsername:
            guard sees(state.plan.usernamePrompt, in: newLines) else { return }
            try? await sendLine(state.plan.username)
            // Skip the password wait when there's nothing to send; some
            // characters have no password.
            state.phase = state.plan.password.isEmpty ? .done : .awaitingPassword
        case .awaitingPassword:
            if sees(state.plan.passwordPrompt, in: newLines) {
                try? await sendLine(state.plan.password, redactInTranscript: true)
                state.phase = .done
            } else if seesInCompletedLines(state.plan.usernamePrompt, in: newLines) {
                // Recovery: the NAME prompt re-appearing here means the
                // login flow restarted under us (stray input at the login
                // screen — Aardwolf re-asks the name; seen live 2026-06-11,
                // where a resume's stranded empty sends dead-ended the login
                // until a manual reconnect). Re-send the name, capped so a
                // prompt-looping server can't make us spam credentials.
                // Completed lines ONLY: the original un-terminated prompt
                // lingers in the pending buffer after we answer it, and
                // matching there re-sent the name on every chunk.
                if state.usernameRetries < 3 {
                    state.usernameRetries += 1
                    try? await sendLine(state.plan.username)
                }
            }
        case .done:
            break
        }

        autologin = state.phase == .done ? nil : state
    }

    /// True if `needle` appears in any of `lines` or in the pipeline's
    /// current un-terminated pending text.
    private func sees(_ needle: String, in lines: [Line]) -> Bool {
        guard !needle.isEmpty else { return false }
        if pipeline.pendingLineText.contains(needle) { return true }
        return seesInCompletedLines(needle, in: lines)
    }

    /// True only for freshly COMPLETED lines — the re-prompt recovery uses
    /// this so the answered (still-pending) original prompt can't re-match.
    private func seesInCompletedLines(_ needle: String, in lines: [Line]) -> Bool {
        guard !needle.isEmpty else { return false }
        return lines.contains { $0.text.contains(needle) }
    }
}

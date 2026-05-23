import Foundation

/// Prompt-driven (Diku-style) auto-login. Extracted from
/// ``SessionController`` to keep that file within the length budget.
extension SessionController {
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
            guard sees(state.plan.passwordPrompt, in: newLines) else { return }
            try? await sendLine(state.plan.password)
            state.phase = .done
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
        return lines.contains { $0.text.contains(needle) }
    }
}

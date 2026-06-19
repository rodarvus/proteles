import Foundation

/// Remote-close handling + the autoreconnect loop (ReconnectPolicy, D-18/D-19).
extension SessionController {
    /// Commands that mean "log me out" — a server close right after one is
    /// expected, not a dropped link. Aardwolf's normal logout is `quit`; the
    /// **force-logout** (required when you hold items that can't be saved) is
    /// `quit quit`. Both actually close the connection, so both must suppress
    /// autoreconnect — matching only `quit` reconnected you the instant you
    /// force-quit. `quit check` (just lists unsaveable items) and `quit <bad
    /// arg>` do NOT log you out, so they're deliberately excluded.
    public static let quitCommands: Set<String> = ["quit", "quit quit"]

    /// Whether `command` is an Aardwolf logout (see ``quitCommands``).
    /// Normalises case and collapses internal whitespace first, so `Quit  Quit`
    /// and a trailing space still count.
    static func isLogoutQuit(_ command: String) -> Bool {
        let normalized = command.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return quitCommands.contains(normalized)
    }

    /// True when a close arriving now is a clean logout: a quit command was
    /// accepted (the close lands within ``cleanQuitWindow`` of it). A refused
    /// quit leaves the connection up, so no close arrives and this never trips.
    private var closedByAcceptedQuit: Bool {
        guard expectsCleanClose, let quitSentAt else { return false }
        return ContinuousClock.now - quitSentAt < Self.cleanQuitWindow
    }

    /// Close the connection. Idempotent. A user-initiated disconnect — it
    /// suppresses autoreconnect and fires the clean-session-end handler (so the
    /// resume breadcrumb is dropped, #42).
    public func disconnect() async {
        userInitiatedDisconnect = true
        cleanSessionEndHandler?() // intentional end → drop the resume breadcrumb (#42)
        isReconnecting = false
        reconnectTask?.cancel()
        reconnectTask = nil
        timerTask?.cancel()
        timerTask = nil

        if let conn = connection {
            teardownSession()
            await conn.disconnect()
            await flushOnDisconnect()
        }
        updateState(.disconnected)
    }

    /// React to the inbound byte stream ending on its own (remote close):
    /// flush any trailing line, tear the session down, then autoreconnect (if
    /// the policy allows and it wasn't a user disconnect/clean quit) or surface
    /// `.disconnected`.
    func handleByteStreamEnded() async {
        guard connection != nil else { return }
        await flushOnDisconnect()
        teardownSession()

        // A quit that PROMPTLY closed the connection is a clean logout — drop
        // the resume breadcrumb so the next launch cold-starts. A close long
        // after a quit (Aardwolf refused it; you kept playing) or with no
        // recent quit at all is the session ending while live — keep the
        // breadcrumb so the next launch resumes (#42).
        if closedByAcceptedQuit { cleanSessionEndHandler?() }

        let shouldReconnect = reconnectPolicy.isEnabled
            && !userInitiatedDisconnect
            && !expectsCleanClose
            && lastEndpoint != nil
        if shouldReconnect {
            beginReconnect()
        } else {
            updateState(.disconnected)
        }
    }

    /// Forward an underlying-connection transition onto the durable stream,
    /// suppressing the transient `.disconnected` of a failed attempt while a
    /// reconnect cycle is in progress.
    func forwardConnectionState(_ newState: State) {
        if isReconnecting, newState == .disconnected { return }
        updateState(newState)
    }

    /// Drive the exponential-backoff reconnect loop. Surfaces `.connecting` for
    /// the duration; ends by either re-establishing the session or, once
    /// ``ReconnectPolicy/maxAttempts`` is hit, emitting `.disconnected`.
    private func beginReconnect() {
        guard let endpoint = lastEndpoint else {
            updateState(.disconnected)
            return
        }
        isReconnecting = true
        updateState(.connecting)

        let policy = reconnectPolicy
        let plan = lastAutologinPlan
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                if policy.maxAttempts > 0, attempt > policy.maxAttempts {
                    await self?.reconnectExhausted()
                    return
                }
                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
                if Task.isCancelled { return }
                let reconnected = await self?.reconnectAttempt(to: endpoint, autologin: plan) ?? false
                if reconnected { return }
                attempt += 1
            }
        }
    }

    /// One reconnection attempt. Returns true on success (loop stops) or if the
    /// user disconnected in the meantime (loop should bail).
    private func reconnectAttempt(
        to endpoint: NetworkConnection.Endpoint,
        autologin plan: AutologinPlan?
    ) async -> Bool {
        guard !userInitiatedDisconnect else { return true }
        do {
            try await establish(to: endpoint, autologin: plan, surfaceFailureState: false)
            isReconnecting = false
            return true
        } catch {
            updateState(.connecting) // stay visibly "connecting" for the next attempt
            return false
        }
    }

    private func reconnectExhausted() {
        isReconnecting = false
        updateState(.disconnected)
    }
}

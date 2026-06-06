import Foundation

/// Remote-close handling + the autoreconnect loop (ReconnectPolicy, D-18/D-19).
extension SessionController {
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

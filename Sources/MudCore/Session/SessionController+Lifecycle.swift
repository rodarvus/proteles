import Foundation

/// Per-session lifecycle plumbing: the inbound byte-processing loop and the
/// teardown that unwinds it. Split from `SessionController.swift` for the
/// 600-line budget (the stored tasks these drive stay in the main file —
/// stored properties can't live in an extension).
extension SessionController {
    func startProcessingLoop(on conn: any MudConnection) {
        processTask?.cancel()
        let bytesStream = conn.bytes
        processTask = Task { [weak self] in
            for await chunk in bytesStream {
                await self?.processChunk(chunk)
            }
            // The byte stream finishing means the peer closed (or the
            // connection failed): wind the session down. A local
            // ``disconnect()`` cancels this task first, so this path only
            // fires for remote-initiated closes.
            await self?.handleByteStreamEnded()
        }
    }

    /// Cancel the per-session tasks and drop the connection so the next
    /// ``connect(to:autologin:)`` starts clean. Idempotent. Does *not*
    /// emit a state transition — callers do that explicitly.
    func teardownSession() {
        processTask?.cancel()
        processTask = nil
        stateForwardTask?.cancel()
        stateForwardTask = nil
        // Stop the timer loop so recurring plugin/S&D timers don't keep firing
        // on a dropped session (re-armed by updateState on the next connect).
        timerTask?.cancel()
        timerTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        pluginActivationFallbackTask?.cancel()
        pluginActivationFallbackTask = nil
        recorder?.close()
        recorder = nil
        transcript?.close()
        transcript = nil
        stopSessionLog()
        autologin = nil
        connection = nil
        dinvLoaded = false // reloads on the next active char.status (e.g. reconnect)
        seenCharInGame = false // re-gate char.status plugin broadcasts until in-game
    }
}

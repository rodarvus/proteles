import Foundation

/// User-facing session logging lifecycle (see ``SessionLogger``): open a log on
/// connect, drain the scrollback stream into it, close on disconnect. Kept
/// separate from the recorder/transcript so the readable-log feature is easy to
/// find. Off by default; the app supplies the per-session file URL.
public extension SessionController {
    /// Open a session log + start draining finalized scrollback lines into it,
    /// if logging is enabled and a URL is available. Called on connect.
    func startSessionLogIfEnabled() {
        guard loggingEnabled, sessionLogger == nil,
              let url = logFileURL(logFormat),
              let logger = SessionLogger(url: url, format: logFormat)
        else { return }
        sessionLogger = logger
        logDrainTask = Task { [weak self, store = scrollbackStore] in
            for await line in await store.subscribe() {
                if Task.isCancelled { break }
                await self?.sessionLogger?.append(line)
            }
        }
    }

    /// Stop + close the current session log (called on disconnect/teardown).
    /// Sync-friendly: the actor close runs in a detached task so it can be
    /// invoked from the synchronous teardown path.
    func stopSessionLog() {
        logDrainTask?.cancel()
        logDrainTask = nil
        guard let logger = sessionLogger else { return }
        sessionLogger = nil
        Task { await logger.close() }
    }

    /// Enable/disable user session logging (takes effect on the next connect).
    func setLoggingEnabled(_ enabled: Bool) {
        loggingEnabled = enabled
    }

    /// Set the log format — text or HTML (takes effect on the next connect).
    func setLogFormat(_ format: SessionLogFormat) {
        logFormat = format
    }
}

import Foundation

/// Live, user-facing preference setters pushed from the UI's persisted toggles
/// (the Preferences window / View menu). Kept together so the settings surface
/// is easy to find and extend.
public extension SessionController {
    /// Set the blank-line omission preference (drop completely-empty lines).
    func setOmitBlankLines(_ enabled: Bool) {
        omitBlankLines = enabled
    }

    /// Enable/disable auto-reconnect. Maps to the standard backoff policy or
    /// none; takes effect on the next drop.
    func setReconnectEnabled(_ enabled: Bool) {
        reconnectPolicy = enabled ? .standard : .disabled
    }

    /// Enable/disable automatic session recording. Takes effect on the next
    /// connection.
    func setAutoRecord(_ enabled: Bool) {
        autoRecord = enabled
    }

    /// Enable/disable the anti-idle keep-alive (telnet NOP). Applies on the
    /// next cadence tick; the loop keeps running so re-enabling needs no
    /// reconnect.
    func setKeepAliveEnabled(_ enabled: Bool) {
        keepAliveEnabled = enabled
    }
}

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
}

import Foundation

/// Thread-safe holder for the current world name, read by the session-log URL
/// closure (which runs off the main actor) and written on the main actor when a
/// world connects. Tiny + lock-guarded so it's safely `Sendable`.
final class LogContext: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    var worldName: String? {
        get { lock.withLock { name } }
        set { lock.withLock { name = newValue } }
    }
}

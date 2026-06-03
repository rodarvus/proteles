import Foundation

/// Collapses duplicate notifications so a burst (a busy channel, a keyword that
/// also matches via another rule, rapid HP ticks) doesn't become a stack of
/// identical banners. Pure value type: the session owns one and calls
/// ``shouldShow(_:now:)`` at the publish gate. A repeat of the same title+body
/// within `window` is suppressed; once the burst stops (a gap longer than
/// `window`), the next identical one shows again.
public struct NotificationCoalescer: Sendable {
    public var window: TimeInterval
    private var lastShown: [String: Date] = [:]

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    /// Whether `note` should be posted now (false = a recent duplicate). A
    /// suppressed hit slides the window so a continuous burst stays collapsed.
    public mutating func shouldShow(_ note: ProtelesNotification, now: Date = Date()) -> Bool {
        let key = note.title + "\u{1}" + note.body
        if let previous = lastShown[key], now.timeIntervalSince(previous) < window {
            lastShown[key] = now // slide: keep collapsing while the burst continues
            return false
        }
        lastShown[key] = now
        // Drop stale keys so the map can't grow unbounded over a long session.
        lastShown = lastShown.filter { now.timeIntervalSince($0.value) < window * 4 }
        return true
    }
}

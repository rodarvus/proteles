import AppKit
import MudCore
import UserNotifications

/// Posts ``ProtelesNotification``s from the session as macOS user notifications
/// (`UNUserNotificationCenter`). Applies the suppress-when-focused policy here
/// (it knows `NSApp.isActive`); the decision of *what* is notification-worthy
/// is the pure ``NotificationMatcher`` in MudCore.
@MainActor
final class NotificationController {
    private let center = UNUserNotificationCenter.current()
    private var requestedAuthorization = false

    /// When true, post notifications even while Proteles is frontmost (the user
    /// opted out of suppress-when-focused). Synced from a preference.
    var notifyWhenFocused = false

    /// Ask for notification permission once (on first enable). Safe to call
    /// repeatedly — the system only prompts the first time.
    func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a notification, honouring suppress-when-focused.
    func post(_ note: ProtelesNotification) {
        if note.suppressWhenFocused, NSApp.isActive, !notifyWhenFocused { return }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        if note.playSound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        center.add(request)
    }
}

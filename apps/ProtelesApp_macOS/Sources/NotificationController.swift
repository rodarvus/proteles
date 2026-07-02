import AppKit
import MudCore
import UserNotifications

/// Posts ``ProtelesNotification``s from the session as macOS user notifications
/// (`UNUserNotificationCenter`). Applies the suppress-when-focused policy here
/// (it knows `NSApp.isActive`); the decision of *what* is notification-worthy
/// is the pure ``NotificationMatcher`` in MudCore.
///
/// Also the center's delegate: without a delegate answering
/// `willPresent`, macOS silently drops any notification posted while the app
/// is frontmost (it lands in the Notification Center list with no banner) —
/// which made "Also notify while Proteles is in focus" a no-op. The
/// wanted-or-not policy is applied in ``post(_:)`` *before* the request
/// reaches the OS, so anything arriving at `willPresent` should present.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var requestedAuthorization = false

    override init() {
        super.init()
        center.delegate = self
    }

    /// Present banners even while Proteles is frontmost — the app-side focus
    /// policy in ``post(_:)`` already decided this notification is wanted.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let title = notification.request.content.title
        Task { @MainActor in
            self.onDeliveryOutcome?("'\(title)' presenting while frontmost (banner+sound)")
        }
        completionHandler([.banner, .list, .sound])
    }

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

    /// Reports each delivery outcome (posted / suppressed / OS error) so the
    /// session can transcript-log it — a silently dropped banner is otherwise
    /// undiagnosable. Set by ``consume(from:)``.
    var onDeliveryOutcome: (@Sendable (String) -> Void)?

    /// Drain the session's notification stream, posting each banner and wiring
    /// delivery outcomes back into the session transcript (NOTIF category).
    /// Runs for the life of the app's notification task.
    func consume(from session: SessionController) async {
        onDeliveryOutcome = { [weak session] outcome in
            guard let session else { return }
            Task { await session.logNotificationDelivery(outcome) }
        }
        for await note in session.notifications {
            await session.logNotificationDelivery("received '\(note.title)', posting")
            post(note)
        }
    }

    /// Post a notification, honouring suppress-when-focused.
    func post(_ note: ProtelesNotification) {
        if note.suppressWhenFocused, NSApp.isActive, !notifyWhenFocused {
            onDeliveryOutcome?("'\(note.title)' suppressed (app focused, notifyWhenFocused off)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        if note.playSound {
            // A named system sound (e.g. "Glass") if the rule chose one, else the
            // default notification sound.
            content.sound = note.soundName.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
                ?? .default
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        let report = onDeliveryOutcome
        center.add(request) { error in
            if let error {
                report?("'\(note.title)' add FAILED: \(error.localizedDescription)")
            } else {
                report?("'\(note.title)' handed to Notification Center")
            }
        }
        center.getNotificationSettings { settings in
            report?("authorization=\(settings.authorizationStatus.rawValue) "
                + "alert=\(settings.alertSetting.rawValue) (2=enabled)")
        }
    }
}

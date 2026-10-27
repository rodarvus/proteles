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
            self.onDeliveryOutcome?("'\(title)' presenting while frontmost (banner)")
        }
        // No `.sound`: the banner carries none — its cue already played (S1 step 5).
        completionHandler([.banner, .list])
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
    /// undiagnosable. Set by ``consume(from:playCue:)``.
    var onDeliveryOutcome: (@Sendable (String) -> Void)?

    /// Plays a posted notification's cue on the app's cue player (S1 step 5).
    private var playCue: (SoundCue) -> Void = { _ in }

    /// Drain the session's notification stream, posting each banner and wiring
    /// delivery outcomes back into the session transcript (NOTIF category).
    /// `playCue` plays a posted banner's sound. Runs for the life of the app's
    /// notification task.
    func consume(from session: SessionController, playCue: @escaping (SoundCue) -> Void) async {
        self.playCue = playCue
        onDeliveryOutcome = { [weak session] outcome in
            guard let session else { return }
            Task { await session.logNotificationDelivery(outcome) }
        }
        for await note in session.notifications {
            await session.logNotificationDelivery("received '\(note.title)', posting")
            post(note)
        }
    }

    /// Post a notification, honouring suppress-when-focused. The banner is
    /// silent: its sound is the notification's cue, played here when — and
    /// only when — the banner posts (S1 step 5, Q3 (a)), so it obeys the cue
    /// map's caps and playback discipline instead of being a second path.
    func post(_ note: ProtelesNotification) {
        if note.suppressWhenFocused, NSApp.isActive, !notifyWhenFocused {
            onDeliveryOutcome?("'\(note.title)' suppressed (app focused, notifyWhenFocused off)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        if let cue = note.cue { playCue(cue) }
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

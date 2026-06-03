import Foundation

/// User-notification wiring: run captured chat lines through the pure
/// ``NotificationMatcher`` (tells/mentions) and publish the results for the app
/// to post via `UNUserNotifications`. Off by default; the app pushes the
/// preference + applies the suppress-when-focused policy. See
/// docs/plans/NOTIFICATIONS_PLAN.md.
public extension SessionController {
    /// Match a freshly captured chat line and publish a notification if it's
    /// notification-worthy (a tell, or your name mentioned on a channel).
    func notifyForChat(_ chatLine: ChatLine) async {
        guard notificationsEnabled else { return }
        let name = await gmcpState.state.base?.name
        if let note = notificationMatcher.notification(for: chatLine, characterName: name) {
            notificationsContinuation.yield(note)
        }
    }

    /// Enable/disable notifications (the master toggle).
    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    /// Toggle the built-in tell + mention rules.
    func setNotificationRules(tells: Bool, mention: Bool) {
        notificationMatcher.notifyOnTells = tells
        notificationMatcher.notifyOnMention = mention
    }

    /// Replace the user's phase-2 custom rules (keyword / channel).
    func setCustomNotificationRules(_ rules: [NotificationRule]) {
        notificationMatcher.rules = rules
    }

    /// Match a displayed output line against the user's `.keyword` rules and
    /// publish a notification if one fires. Gated + cheap: returns immediately
    /// unless notifications are on and at least one keyword rule exists.
    func notifyForOutput(_ text: String) {
        guard notificationsEnabled, notificationMatcher.hasOutputRules else { return }
        if let note = notificationMatcher.outputNotification(for: text) {
            notificationsContinuation.yield(note)
        }
    }

    /// Publish a script/plugin-raised notification (`Notify(...)` / `proteles
    /// .notify`), gated by the master enable. The extensibility hook.
    func notifyFromScript(title: String, body: String) {
        guard notificationsEnabled else { return }
        notificationsContinuation.yield(ProtelesNotification(title: title, body: body))
    }
}

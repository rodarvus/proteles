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
            publishNotification(note)
        }
    }

    /// The single publish gate: drop a recent duplicate (coalescing), else yield
    /// the notification for the app to post.
    func publishNotification(_ note: ProtelesNotification) {
        guard notificationCoalescer.shouldShow(note) else { return }
        notificationsContinuation.yield(note)
    }

    /// Edge-triggered low-HP check: recompute HP% from GMCP vitals/maxstats and
    /// fire any `.hpBelow` rule the player just crossed. Called after a
    /// `char.vitals`/`char.maxstats` update.
    func checkHPNotifications() async {
        guard notificationsEnabled, notificationMatcher.hasHPRules else { return }
        let state = await gmcpState.state
        guard let hp = state.vitals?.hp, let maxHP = state.maxStats?.maxhp, maxHP > 0 else { return }
        let percent = Int((Double(hp) / Double(maxHP)) * 100)
        let notes = notificationMatcher.hpNotifications(
            currentPercent: percent,
            previousPercent: lastHPPercent
        )
        lastHPPercent = percent
        for note in notes {
            publishNotification(note)
        }
    }

    /// Quest-ready check off the published S&D model: fire on the
    /// `canRequestQuest` `false → true` edge. Gated to S&D's bridge JSON.
    func checkQuestReady(_ json: String) {
        guard notificationsEnabled, json.contains("can_request_quest"),
              let model = SearchAndDestroyModel.decode(json) else { return }
        let ready = model.canRequestQuest
        defer { lastQuestReady = ready }
        guard ready, !lastQuestReady,
              let note = notificationMatcher.questReadyNotification(becameReady: true) else { return }
        publishNotification(note)
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
            publishNotification(note)
        }
    }

    /// Publish a script/plugin-raised notification (`Notify(...)` / `proteles
    /// .notify`), gated by the master enable. The extensibility hook.
    func notifyFromScript(title: String, body: String) {
        guard notificationsEnabled else { return }
        publishNotification(ProtelesNotification(title: title, body: body))
    }
}

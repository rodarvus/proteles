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
        guard notificationsEnabled else {
            logTranscript(.notif, "chat chan=\(chatLine.channel) → skipped (notifications disabled)")
            return
        }
        let name = await gmcpState.state.base?.name
        let note = notificationMatcher.notification(for: chatLine, characterName: name)
        logTranscript(
            .notif,
            "chat chan=\(chatLine.channel) player=\(chatLine.player) "
                + "name=\(name ?? "<nil>") tells=\(notificationMatcher.notifyOnTells) "
                + "mention=\(notificationMatcher.notifyOnMention) rules=\(notificationMatcher.rules.count) "
                + "→ \(note.map { "match '\($0.title)'" } ?? "no-match")"
        )
        if let note {
            publishNotification(note)
        }
    }

    /// The single publish gate: drop a recent duplicate (coalescing), else yield
    /// the notification for the app to post.
    func publishNotification(_ note: ProtelesNotification) {
        guard notificationCoalescer.shouldShow(note) else {
            logTranscript(.notif, "publish '\(note.title)' → coalesced (duplicate within window)")
            return
        }
        let result = notificationsContinuation.yield(note)
        logTranscript(.notif, "publish '\(note.title)' → yielded to app (\(result))")
    }

    /// App-layer delivery outcomes (posted / focus-suppressed / OS error) written
    /// back into the transcript, so a recording shows the WHOLE chain — the app
    /// side is otherwise invisible to recordings.
    func logNotificationDelivery(_ outcome: String) {
        logTranscript(.notif, "app: \(outcome)")
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

    /// Run GMCP-driven notification checks after a packet is applied. One entry
    /// point (called unconditionally) so `dispatchGMCP` stays branch-light; the
    /// per-package gating lives here.
    func checkGMCPNotifications(package: String, json: String) async {
        await checkHPNotifications()
        if package.lowercased() == "comm.quest" { checkQuestReady(json) }
    }

    /// Quest-ready from Aardwolf's `comm.quest` GMCP — fire on the not-ready →
    /// ready edge. Pure GMCP, no S&D dependency (S&D reads the same packet). The
    /// "ready" conditions come from the reference's `quest_status_gmcp`.
    func checkQuestReady(_ json: String) {
        guard notificationsEnabled, notificationMatcher.hasQuestReadyRule,
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = object["action"] as? String else { return }
        let ready = NotificationMatcher.commQuestIsReady(action: action, status: object["status"] as? String)
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

    /// Raise a banner for a new group invitation. Aardwolf sends no GMCP for
    /// invites, so this is driven by ``handleGroupInviteLine``'s text parsing.
    /// Behaves like the tell/keyword banners — gated by the master toggle and
    /// the suppress-when-focused policy (the always-visible reminder is the
    /// Group panel's pending-invite list, which the banner complements when
    /// you're tabbed away).
    func notifyGroupInvite(inviter: String, groupName: String) {
        guard notificationsEnabled else { return }
        publishNotification(ProtelesNotification(
            title: "Group invite from \(inviter)",
            body: "Join “\(groupName)”? Use ‘group accept \(inviter)’ or ‘group decline \(inviter)’."
        ))
    }
}

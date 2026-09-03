import Foundation

/// The user rule engine as a **source of `SemanticEvent`s** — S0a item 4
/// (GitHub #82, D-118 "NotificationMatcher generalized as the user rule engine").
///
/// Before this, Proteles ran two independent matchers over the same displayed
/// text: the built-in vocabulary (`SoundEventClassifier`, now behind
/// `SemanticClassifier`) and the user's `NotificationRule`s. This makes the
/// second one emit events too, and builds each notification *from* its event —
/// so notifications become a consumer of the semantic layer rather than a
/// parallel path beside it. That is one of the three matchers IOS_PORT_PLAN §1.5
/// says are secretly one layer.
///
/// ## Scope, deliberately (D-122 product principle: wholesale V1)
///
/// **Option A only:** rules *produce* events. There are no rules keyed *on*
/// events (no "notify me on any `.combat` event"), no new trigger kinds, no UI
/// and no change to the persisted `NotificationRule` — user-defined events and
/// per-category controls are not a V1 goal. The generalisation is a seam.
///
/// **Behaviour-neutral:** the existing `outputNotification` /
/// `notification(for:)` / `hpNotifications` / `questReadyNotification` keep
/// their signatures and results; they are now implemented on top of the event
/// path. Parity is tested per trigger kind.
///
/// **Built-in tells and mentions are not rules** and are unchanged — they are
/// preferences (`notifyOnTells`, `notifyOnMention`), not `NotificationRule`s.
/// A tell already has a vocabulary event (`tell`, from `comm.channel`); deriving
/// the tell *notification* from that event is a natural follow-up once events
/// are on the bus (item 6). Mentions have no event today.
///
/// ## Source tiering is not cosmetic
///
/// A `.keyword` rule is exactly as fragile as any other prose match, so its event
/// is `.pattern`. `.hpBelow` reads GMCP vitals and is `.gmcp`. The layer records
/// that a user's keyword rule is the weakest tier, because it is.
public extension NotificationMatcher {
    /// Prefix of every rule-derived event name; the remainder is the rule's id.
    static let ruleEventPrefix = "rule."

    // MARK: - Events

    /// One event per enabled `.keyword` rule that matches `line`, in rule order.
    /// The caller's `hasOutputRules` short-circuit stays *ahead* of this, so a
    /// player with no keyword rules pays nothing — the guard-order discipline
    /// from the S0a wiring (see `S0A_WIRING_PROPOSAL.md`).
    func events(forDisplayed line: String) -> [SemanticEvent] {
        rules.compactMap { rule in
            guard rule.enabled, case .keyword(let phrase) = rule.trigger, !phrase.isEmpty,
                  let captured = Self.keywordMatch(line, phrase: phrase, regex: rule.regex)
            else { return nil }
            return SemanticEvent(
                // Placeholder. A keyword rule watches arbitrary text and the
                // layer cannot know what it means; no consumer reads a user
                // rule's category in V1 (D-122). Revisit only if one appears.
                category: .system,
                name: Self.eventName(for: rule),
                source: .pattern(rule: "user.\(rule.displayLabel)"),
                payload: [
                    "phrase": phrase,
                    "line": line,
                    "match": captured,
                    "capture": captured
                ]
            )
        }
    }

    /// One event per enabled `.channel` rule matching `chatLine`'s channel. The
    /// `mobsay` suppression applies here exactly as it does to notifications.
    func events(forChat chatLine: ChatLine) -> [SemanticEvent] {
        guard case .channel = chatLine.source else { return [] }
        let channel = chatLine.channel.lowercased()
        guard !Self.suppressesNotifications(forChannel: channel) else { return [] }
        let message = chatLine.line.text
        let sender = chatLine.player.trimmingCharacters(in: .whitespaces)
        return rules.compactMap { rule in
            guard rule.enabled, case .channel(let name) = rule.trigger, !name.isEmpty,
                  channel.contains(name.lowercased())
            else { return nil }
            return SemanticEvent(
                category: .communication,
                name: Self.eventName(for: rule),
                source: .gmcp(package: "comm.channel"),
                payload: [
                    "channel": chatLine.channel,
                    "player": sender,
                    "message": message,
                    "line": message
                ]
            )
        }
    }

    /// One event per enabled `.hpBelow` rule the player just crossed below.
    /// Edge-triggered: was at/above `threshold` (or unknown) → now below.
    func events(forHPPercent current: Int?, previous: Int?) -> [SemanticEvent] {
        guard let current else { return [] }
        return rules.compactMap { rule in
            guard rule.enabled, case .hpBelow(let threshold) = rule.trigger else { return nil }
            let wasAtOrAbove = previous.map { $0 >= threshold } ?? true
            guard current < threshold, wasAtOrAbove else { return nil }
            return SemanticEvent(
                category: .combat,
                name: Self.eventName(for: rule),
                source: .gmcp(package: "char.vitals"),
                payload: ["percent": "\(current)", "threshold": "\(threshold)"]
            )
        }
    }

    /// One event per enabled `.questReady` rule, when the player just became
    /// able to request a quest (the caller detects the edge from `comm.quest`).
    func events(forQuestReady becameReady: Bool) -> [SemanticEvent] {
        guard becameReady else { return [] }
        return rules.compactMap { rule in
            guard rule.enabled, case .questReady = rule.trigger else { return nil }
            return SemanticEvent(
                category: .world,
                name: Self.eventName(for: rule),
                source: .gmcp(package: "comm.quest"),
                payload: [:]
            )
        }
    }

    // MARK: - Notifications, built from events

    /// The notification a rule event represents, or `nil` if the event is not a
    /// rule event or its rule no longer exists. Title/body come from the rule's
    /// templates over the event's payload, else the same per-kind defaults the
    /// pre-event path produced — which is what keeps this behaviour-neutral.
    func notification(from event: SemanticEvent) -> ProtelesNotification? {
        guard let rule = rule(for: event) else { return nil }
        let payload = event.payload
        let defaults: (title: String, body: String)
        switch rule.trigger {
        case .keyword:
            defaults = ("Match: \(payload["phrase"] ?? "")", payload["line"] ?? "")
        case .channel:
            let channel = payload["channel"] ?? ""
            let player = payload["player"] ?? ""
            let message = payload["message"] ?? ""
            defaults = (
                channel.isEmpty ? "Channel" : channel,
                player.isEmpty ? message : "\(player): \(message)"
            )
        case .hpBelow:
            let percent = payload["percent"] ?? "?"
            let threshold = payload["threshold"] ?? "?"
            defaults = ("Low HP", "HP at \(percent)% (below \(threshold)%)")
        case .questReady:
            defaults = ("Quest ready", "You can request a new quest.")
        }
        return make(rule: rule, defaultTitle: defaults.title, defaultBody: defaults.body, tokens: payload)
    }

    /// The rule a rule-event names, if it still exists.
    func rule(for event: SemanticEvent) -> NotificationRule? {
        guard event.name.hasPrefix(Self.ruleEventPrefix) else { return nil }
        let id = String(event.name.dropFirst(Self.ruleEventPrefix.count))
        return rules.first { $0.id.uuidString == id }
    }

    /// `rule.<uuid>` — stable for the session and disjoint from the built-in
    /// vocabulary's names, so a consumer can tell the two sources apart by name
    /// as well as by `source`.
    static func eventName(for rule: NotificationRule) -> String {
        ruleEventPrefix + rule.id.uuidString
    }
}

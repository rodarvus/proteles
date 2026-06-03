import Foundation

/// A user-configurable notification rule (Notifications phase-2, GH #14). Kept
/// deliberately lean (see docs/plans/NOTIFICATIONS_PLAN.md "Phase-2 build
/// decisions"): a keyword on any output line, or any chat on a named channel.
/// Codable so the app can persist the set in UserDefaults and push it to the
/// session's ``NotificationMatcher``. Richer triggers (regex, GMCP thresholds,
/// title/body templates, per-rule sound) are a phase-3 follow-up; power users
/// get regex today via a trigger that calls `Notify(...)`.
public struct NotificationRule: Sendable, Equatable, Codable, Identifiable {
    public enum Trigger: Sendable, Equatable, Codable {
        /// Case-insensitive substring match against any incoming output line.
        case keyword(String)
        /// Any chat line on a named channel (case-insensitive, substring of the
        /// channel name — so "gossip" matches the "gossip" channel).
        case channel(String)
    }

    public var id: UUID
    /// A short user label for the rule list; falls back to the trigger text.
    public var label: String
    public var trigger: Trigger
    public var enabled: Bool

    public init(id: UUID = UUID(), label: String = "", trigger: Trigger, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.trigger = trigger
        self.enabled = enabled
    }

    /// The trigger's text (keyword phrase or channel name), for display + matching.
    public var triggerText: String {
        switch trigger {
        case .keyword(let text), .channel(let text): text
        }
    }

    /// The label to show in the UI (the user label, else a sensible default).
    public var displayLabel: String {
        if !label.isEmpty { return label }
        switch trigger {
        case .keyword(let text): return "Keyword: \(text)"
        case .channel(let text): return "Channel: \(text)"
        }
    }
}

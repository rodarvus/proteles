import Foundation

/// A user-configurable notification rule (Notifications phase-2/3, GH #14).
/// Phase-2 shipped keyword + channel triggers; phase-3 adds GMCP-driven triggers
/// (low HP, quest-ready), an optional regex keyword, a per-rule sound, and
/// optional title/body templates with tokens. Codable so the app persists the
/// set in UserDefaults and pushes it to the session's ``NotificationMatcher``.
public struct NotificationRule: Sendable, Equatable, Codable, Identifiable {
    public enum Trigger: Sendable, Equatable, Codable {
        /// Substring (or regex, if `rule.regex`) match against any output line.
        case keyword(String)
        /// Any chat line on a named channel (case-insensitive substring).
        case channel(String)
        /// Your HP drops below this percent (edge-triggered, from GMCP vitals).
        case hpBelow(Int)
        /// A new quest can be requested (from the S&D quest tracker).
        case questReady
    }

    /// A per-rule notification sound. `default` uses the system default; `silent`
    /// plays none; the rest name a macOS system sound.
    public enum Sound: String, Sendable, Equatable, Codable, CaseIterable {
        case `default`, silent, glass, ping, submarine, hero, funk

        public var displayName: String {
            switch self {
            case .default: "Default"
            case .silent: "Silent"
            case .glass: "Glass"
            case .ping: "Ping"
            case .submarine: "Submarine"
            case .hero: "Hero"
            case .funk: "Funk"
            }
        }

        /// The macOS system sound name (e.g. "Glass"), or nil for default/silent.
        public var systemName: String? {
            switch self {
            case .default, .silent: nil
            case .glass: "Glass"
            case .ping: "Ping"
            case .submarine: "Submarine"
            case .hero: "Hero"
            case .funk: "Funk"
            }
        }
    }

    public var id: UUID
    /// A short user label for the rule list; falls back to the trigger text.
    public var label: String
    public var trigger: Trigger
    public var enabled: Bool
    /// Treat a `.keyword` phrase as a regular expression (else substring).
    public var regex: Bool
    public var sound: Sound
    /// Optional title/body overrides with `{...}` tokens; empty = a sensible
    /// default built from the trigger + matched content.
    public var titleTemplate: String
    public var bodyTemplate: String

    public init(
        id: UUID = UUID(),
        label: String = "",
        trigger: Trigger,
        enabled: Bool = true,
        regex: Bool = false,
        sound: Sound = .default,
        titleTemplate: String = "",
        bodyTemplate: String = ""
    ) {
        self.id = id
        self.label = label
        self.trigger = trigger
        self.enabled = enabled
        self.regex = regex
        self.sound = sound
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
    }

    /// Tolerant decode so phase-2 rules (only id/label/trigger/enabled) still
    /// load after the phase-3 fields were added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        regex = try container.decodeIfPresent(Bool.self, forKey: .regex) ?? false
        sound = try container.decodeIfPresent(Sound.self, forKey: .sound) ?? .default
        titleTemplate = try container.decodeIfPresent(String.self, forKey: .titleTemplate) ?? ""
        bodyTemplate = try container.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? ""
    }

    /// The trigger's text (keyword phrase / channel name / "" otherwise).
    public var triggerText: String {
        switch trigger {
        case .keyword(let text), .channel(let text): text
        case .hpBelow, .questReady: ""
        }
    }

    /// The label to show in the UI (the user label, else a sensible default).
    public var displayLabel: String {
        if !label.isEmpty { return label }
        switch trigger {
        case .keyword(let text): return "\(regex ? "Regex" : "Keyword"): \(text)"
        case .channel(let text): return "Channel: \(text)"
        case .hpBelow(let percent): return "HP below \(percent)%"
        case .questReady: return "Quest ready"
        }
    }
}

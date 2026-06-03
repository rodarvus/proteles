import Foundation

/// A user notification Proteles wants to surface (a tell, a mention, or a
/// script/plugin-raised alert). Platform-agnostic; the app layer posts it via
/// `UNUserNotificationCenter`.
public struct ProtelesNotification: Sendable, Equatable {
    public let title: String
    public let body: String
    /// Play a sound (false = silent).
    public let playSound: Bool
    /// A macOS system sound name (e.g. "Glass"); `nil` = the default sound.
    public let soundName: String?
    /// Suppress this notification while Proteles is the frontmost app (the app
    /// layer checks focus). Critical alerts can set this false to always notify.
    public let suppressWhenFocused: Bool

    public init(
        title: String,
        body: String,
        playSound: Bool = true,
        soundName: String? = nil,
        suppressWhenFocused: Bool = true
    ) {
        self.title = title
        self.body = body
        self.playSound = playSound
        self.soundName = soundName
        self.suppressWhenFocused = suppressWhenFocused
    }
}

/// Pure logic deciding whether a chat line warrants a notification — the
/// built-in **tells** + **name-mention** rules (the MVP; user-configurable
/// rules + GMCP-threshold rules are a follow-up, see
/// docs/plans/NOTIFICATIONS_PLAN.md). No `UNUserNotifications`, no focus state
/// (the app applies suppress-when-focused), so it's fully unit-testable.
public struct NotificationMatcher: Sendable, Equatable {
    public var notifyOnTells: Bool
    public var notifyOnMention: Bool
    /// User-configured phase-2 rules (keyword on output, channel on chat).
    public var rules: [NotificationRule]

    public init(
        notifyOnTells: Bool = true,
        notifyOnMention: Bool = true,
        rules: [NotificationRule] = []
    ) {
        self.notifyOnTells = notifyOnTells
        self.notifyOnMention = notifyOnMention
        self.rules = rules
    }

    /// A notification for `chatLine` (a `comm.channel` line), or `nil`. Tells win
    /// over mentions, then a user `.channel` rule; a mention only fires when your
    /// `characterName` appears in a *non-tell* channel message you didn't send.
    public func notification(for chatLine: ChatLine, characterName: String?) -> ProtelesNotification? {
        let channel = chatLine.channel.lowercased()
        let message = chatLine.line.text
        let sender = chatLine.player.trimmingCharacters(in: .whitespaces)

        if notifyOnTells, channel.contains("tell") {
            let from = sender.isEmpty ? "Someone" : sender
            return ProtelesNotification(title: "Tell from \(from)", body: message)
        }

        if mentionFires(message: message, sender: sender, characterName: characterName) {
            let who = sender.isEmpty ? "You were mentioned" : "\(sender) mentioned you"
            let location = chatLine.channel.isEmpty ? "" : " on \(chatLine.channel)"
            return ProtelesNotification(title: who + location, body: message)
        }

        // A user `.channel` rule fires on any chat for the named channel.
        if let rule = firstChannelRule(channel: channel) {
            let defaultBody = sender.isEmpty ? message : "\(sender): \(message)"
            return make(
                rule: rule,
                defaultTitle: chatLine.channel.isEmpty ? "Channel" : chatLine.channel,
                defaultBody: defaultBody,
                tokens: ["channel": chatLine.channel, "player": sender, "message": message, "line": message]
            )
        }
        return nil
    }

    /// An edge-triggered low-HP notification per `.hpBelow` rule that the player
    /// just crossed below (was at/above `threshold` or unknown → now below).
    /// `percent` values are pre-computed by the caller from GMCP vitals/maxstats.
    public func hpNotifications(currentPercent: Int?, previousPercent: Int?) -> [ProtelesNotification] {
        guard let current = currentPercent else { return [] }
        return rules.compactMap { rule in
            guard rule.enabled, case .hpBelow(let threshold) = rule.trigger else { return nil }
            let wasAtOrAbove = previousPercent.map { $0 >= threshold } ?? true
            guard current < threshold, wasAtOrAbove else { return nil }
            return make(
                rule: rule,
                defaultTitle: "Low HP",
                defaultBody: "HP at \(current)% (below \(threshold)%)",
                tokens: ["percent": "\(current)", "threshold": "\(threshold)"]
            )
        }
    }

    /// A quest-ready notification if the player just became able to request one
    /// (the caller detects the `false → true` edge from the S&D quest tracker).
    public func questReadyNotification(becameReady: Bool) -> ProtelesNotification? {
        guard becameReady else { return nil }
        for rule in rules where rule.enabled {
            if case .questReady = rule.trigger {
                return make(
                    rule: rule,
                    defaultTitle: "Quest ready",
                    defaultBody: "You can request a new quest.",
                    tokens: [:]
                )
            }
        }
        return nil
    }

    /// Whether any enabled `.keyword` rule exists — lets the per-line output
    /// path skip the matcher entirely when there's nothing to match.
    public var hasOutputRules: Bool {
        rules.contains { rule in
            guard rule.enabled, case .keyword = rule.trigger else { return false }
            return true
        }
    }

    /// Whether any enabled `.hpBelow` rule exists — lets the per-vitals HP check
    /// skip the matcher when there's nothing to evaluate.
    public var hasHPRules: Bool {
        rules.contains { rule in
            guard rule.enabled, case .hpBelow = rule.trigger else { return false }
            return true
        }
    }

    /// A notification for an arbitrary output `line`, or `nil` — the first
    /// enabled `.keyword` rule whose phrase appears (case-insensitively) in it.
    /// Channel/tell/mention rules are chat-only (see ``notification(for:characterName:)``).
    public func outputNotification(for line: String) -> ProtelesNotification? {
        for rule in rules where rule.enabled {
            guard case .keyword(let phrase) = rule.trigger, !phrase.isEmpty,
                  let captured = Self.keywordMatch(line, phrase: phrase, regex: rule.regex)
            else { continue }
            return make(
                rule: rule,
                defaultTitle: "Match: \(phrase)",
                defaultBody: line,
                tokens: ["line": line, "match": captured, "capture": captured]
            )
        }
        return nil
    }

    /// The matched text for a keyword rule, or `nil`. A regex rule returns its
    /// first capture group (else the whole match); a plain rule the matched
    /// substring. Both are case-insensitive.
    static func keywordMatch(_ line: String, phrase: String, regex: Bool) -> String? {
        guard regex else {
            return line.range(of: phrase, options: .caseInsensitive).map { String(line[$0]) }
        }
        guard let expression = try? NSRegularExpression(pattern: phrase, options: .caseInsensitive),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
        return Range(group, in: line).map { String(line[$0]) } ?? phrase
    }

    /// The first enabled `.channel` rule matching `channel` (already lowercased).
    private func firstChannelRule(channel: String) -> NotificationRule? {
        rules.first { rule in
            guard rule.enabled, case .channel(let name) = rule.trigger, !name.isEmpty else { return false }
            return channel.contains(name.lowercased())
        }
    }

    /// Build a notification for a fired `rule`: title/body from its templates
    /// (with `{token}` substitution) or the supplied defaults, and its sound.
    private func make(
        rule: NotificationRule,
        defaultTitle: String,
        defaultBody: String,
        tokens: [String: String]
    ) -> ProtelesNotification {
        // Title precedence: explicit template → the rule's label → the default.
        let title: String = if !rule.titleTemplate.isEmpty {
            Self.fill(rule.titleTemplate, tokens)
        } else if !rule.label.isEmpty {
            rule.label
        } else {
            defaultTitle
        }
        return ProtelesNotification(
            title: title,
            body: rule.bodyTemplate.isEmpty ? defaultBody : Self.fill(rule.bodyTemplate, tokens),
            playSound: rule.sound != .silent,
            soundName: rule.sound.systemName
        )
    }

    /// Replace `{token}` placeholders in `template` with their values.
    static func fill(_ template: String, _ tokens: [String: String]) -> String {
        tokens.reduce(template) { result, pair in
            result.replacingOccurrences(of: "{\(pair.key)}", with: pair.value)
        }
    }

    /// Whether a non-tell `message` mentions the player by name — only when
    /// mentions are enabled, the player has a name, and it isn't a line they
    /// sent themselves.
    private func mentionFires(message: String, sender: String, characterName: String?) -> Bool {
        guard notifyOnMention,
              let name = characterName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              sender.caseInsensitiveCompare(name) != .orderedSame
        else { return false }
        return Self.mentions(message, name: name)
    }

    /// Case-insensitive, whole-word containment of `name` in `text` (so "al"
    /// doesn't match "alarm" but "Al" matches "hey Al!").
    static func mentions(_ text: String, name: String) -> Bool {
        let lowerText = text.lowercased()
        let lowerName = name.lowercased()
        guard !lowerName.isEmpty else { return false }
        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: lowerName, range: searchStart..<lowerText.endIndex) {
            let before = range.lowerBound == lowerText.startIndex
                ? nil : lowerText[lowerText.index(before: range.lowerBound)]
            let after = range.upperBound == lowerText.endIndex
                ? nil : lowerText[range.upperBound]
            if !isWordChar(before), !isWordChar(after) { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isWordChar(_ char: Character?) -> Bool {
        guard let char else { return false }
        return char.isLetter || char.isNumber
    }
}

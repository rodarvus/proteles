import Foundation

/// A user notification Proteles wants to surface (a tell, a mention, or a
/// script/plugin-raised alert). Platform-agnostic; the app layer posts it via
/// `UNUserNotificationCenter`.
public struct ProtelesNotification: Sendable, Equatable {
    public let title: String
    public let body: String
    /// Play the default notification sound.
    public let playSound: Bool
    /// Suppress this notification while Proteles is the frontmost app (the app
    /// layer checks focus). Critical alerts can set this false to always notify.
    public let suppressWhenFocused: Bool

    public init(title: String, body: String, playSound: Bool = true, suppressWhenFocused: Bool = true) {
        self.title = title
        self.body = body
        self.playSound = playSound
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
        if channelRuleFires(channel: channel) {
            let title = chatLine.channel.isEmpty ? "Channel" : chatLine.channel
            let body = sender.isEmpty ? message : "\(sender): \(message)"
            return ProtelesNotification(title: title, body: body)
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

    /// A notification for an arbitrary output `line`, or `nil` — the first
    /// enabled `.keyword` rule whose phrase appears (case-insensitively) in it.
    /// Channel/tell/mention rules are chat-only (see ``notification(for:characterName:)``).
    public func outputNotification(for line: String) -> ProtelesNotification? {
        for rule in rules where rule.enabled {
            guard case .keyword(let phrase) = rule.trigger, !phrase.isEmpty,
                  line.range(of: phrase, options: .caseInsensitive) != nil
            else { continue }
            let title = rule.label.isEmpty ? "Match: \(phrase)" : rule.label
            return ProtelesNotification(title: title, body: line)
        }
        return nil
    }

    /// Whether an enabled `.channel` rule matches `channel` (already lowercased).
    private func channelRuleFires(channel: String) -> Bool {
        rules.contains { rule in
            guard rule.enabled, case .channel(let name) = rule.trigger, !name.isEmpty else { return false }
            return channel.contains(name.lowercased())
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

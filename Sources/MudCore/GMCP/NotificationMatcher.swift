import Foundation

/// A user notification Proteles wants to surface (a tell, a mention, or a
/// script/plugin-raised alert). Platform-agnostic; the app layer posts it via
/// `UNUserNotificationCenter`.
public struct ProtelesNotification: Sendable, Equatable {
    public let title: String
    public let body: String
    /// The sound chosen for it — a rule's choice, else the default.
    public let sound: NotificationRule.Sound
    /// The cue the app plays when it posts the banner (S1 step 5): made by
    /// the cue map from ``sound`` when the session publishes, so category
    /// caps and playback discipline apply. Nil for a silent one. The banner
    /// itself carries no sound.
    public var cue: SoundCue?
    /// Suppress this notification while Proteles is the frontmost app (the app
    /// layer checks focus). Critical alerts can set this false to always notify.
    public let suppressWhenFocused: Bool

    /// The one event every notification's sound plays as (D-127 (4)).
    public static let soundEvent = "notification"

    public init(
        title: String,
        body: String,
        sound: NotificationRule.Sound = .default,
        cue: SoundCue? = nil,
        suppressWhenFocused: Bool = true
    ) {
        self.title = title
        self.body = body
        self.sound = sound
        self.cue = cue
        self.suppressWhenFocused = suppressWhenFocused
    }

    /// The event this notification's sound emits, or nil when it is silent.
    /// Its payload names the file, as a trigger's file sound does.
    public var soundCueEvent: SemanticEvent? {
        sound.cueFile.map { file in
            SemanticEvent(
                category: .notification,
                name: Self.soundEvent,
                source: .pattern(rule: "notification"),
                payload: [TriggerSound.filePayloadKey: file]
            )
        }
    }
}

/// Pure logic deciding whether a chat line warrants a notification — the
/// built-in **tells** + **name-mention** preferences plus the user's
/// ``NotificationRule``s (keyword, channel, HP threshold, quest-ready). No
/// `UNUserNotifications`, no focus state (the app applies suppress-when-focused),
/// so it's fully unit-testable.
///
/// Since S0a item 4 (#82) the rules are a **source of `SemanticEvent`s** — see
/// `NotificationMatcher+SemanticEvents.swift`. The rule-driven notification
/// methods below are implemented on top of that event path, so a notification is
/// *built from* its event rather than produced beside it. Tells and mentions are
/// preferences, not rules, and are unchanged.
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
    /// over mentions, then a user `.channel` rule; `mobsay` is always silent,
    /// and a mention only fires when your `characterName` appears in a
    /// *non-tell* channel message you didn't send.
    public func notification(for chatLine: ChatLine, characterName: String?) -> ProtelesNotification? {
        guard case .channel = chatLine.source else { return nil }
        let channel = chatLine.channel.lowercased()
        let message = chatLine.line.text
        let sender = chatLine.player.trimmingCharacters(in: .whitespaces)

        guard !Self.suppressesNotifications(forChannel: channel) else { return nil }
        let selfAuthored = Self.isSelfAuthored(
            channel: channel,
            message: message,
            sender: sender,
            characterName: characterName
        )

        if notifyOnTells, channel == "tell", !selfAuthored {
            let from = sender.isEmpty ? "Someone" : sender
            return ProtelesNotification(title: "Tell from \(from)", body: message)
        }

        let shouldNotifyMention = !selfAuthored
            && mentionFires(message: message, sender: sender, characterName: characterName)
        if shouldNotifyMention {
            let who = sender.isEmpty ? "You were mentioned" : "\(sender) mentioned you"
            let location = chatLine.channel.isEmpty ? "" : " on \(chatLine.channel)"
            return ProtelesNotification(title: who + location, body: message)
        }

        // A user `.channel` rule fires on any chat for the named channel —
        // via its event (S0a item 4). First match wins, as before.
        return events(forChat: chatLine).first.flatMap(notification(from:))
    }

    /// An edge-triggered low-HP notification per `.hpBelow` rule that the player
    /// just crossed below (was at/above `threshold` or unknown → now below).
    /// `percent` values are pre-computed by the caller from GMCP vitals/maxstats.
    public func hpNotifications(currentPercent: Int?, previousPercent: Int?) -> [ProtelesNotification] {
        events(forHPPercent: currentPercent, previous: previousPercent)
            .compactMap(notification(from:))
    }

    /// Whether any enabled `.questReady` rule exists — lets the `comm.quest`
    /// GMCP path skip work when there's nothing to fire.
    public var hasQuestReadyRule: Bool {
        rules.contains { rule in
            guard rule.enabled, case .questReady = rule.trigger else { return false }
            return true
        }
    }

    /// Whether an Aardwolf `comm.quest` GMCP message means "you can request a new
    /// quest now". Mirrors the reference's `quest_status_gmcp` (S&D) which sets
    /// `qstat = "0"` on `action == "ready"`/`"timeout"`, or `action == "status"`
    /// with `status == "ready"`. Case-insensitive. No S&D dependency — pure GMCP.
    public static func commQuestIsReady(action: String?, status: String?) -> Bool {
        let action = action?.lowercased()
        let status = status?.lowercased()
        if action == "ready" || action == "timeout" { return true }
        return action == "status" && status == "ready"
    }

    /// A quest-ready notification if the player just became able to request one
    /// (the caller detects the `false → true` edge from `comm.quest` GMCP).
    public func questReadyNotification(becameReady: Bool) -> ProtelesNotification? {
        events(forQuestReady: becameReady).first.flatMap(notification(from:))
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
        events(forDisplayed: line).first.flatMap(notification(from:))
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

    static func suppressesNotifications(forChannel channel: String) -> Bool {
        channel.trimmingCharacters(in: .whitespacesAndNewlines) == "mobsay"
    }

    /// Build a notification for a fired `rule`: title/body from its templates
    /// (with `{token}` substitution) or the supplied defaults, and its sound.
    /// Internal so the event path (`NotificationMatcher+SemanticEvents`) is the
    /// one place notifications are assembled from.
    func make(
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
            sound: rule.sound
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
              !Self.senderIsCharacter(sender, name: name)
        else { return false }
        return Self.mentions(message, name: name)
    }

    private static func isSelfAuthored(
        channel: String,
        message: String,
        sender: String,
        characterName: String?
    ) -> Bool {
        guard let name = characterName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return false }
        if senderIsCharacter(sender, name: name) { return true }
        guard sender.isEmpty else { return false }

        let text = message.lowercased()
        let player = name.lowercased()
        switch channel {
        case "claninfo":
            return text.hasPrefix("clan: \(player) has returned")
                || (text.hasPrefix("clan: \(player),") && text.contains("must now leave"))
        case "group":
            return text.hasPrefix("(group) \(player) has joined the group")
                || text.hasPrefix("(group) warning: \(player) is too strong")
        case "market":
            return text.hasPrefix("market: \(player) is selling ")
        case "auction":
            return text.hasPrefix("auction: \(player) has placed a bid ")
        default:
            return false
        }
    }

    /// GMCP sometimes prefixes the speaker with an Aardwolf title. Player
    /// names contain no spaces, so the final sender token is authoritative.
    private static func senderIsCharacter(_ sender: String, name: String) -> Bool {
        let finalToken = sender.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let trimmed = finalToken.trimmingCharacters(in: .punctuationCharacters)
        return trimmed.caseInsensitiveCompare(name) == .orderedSame
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

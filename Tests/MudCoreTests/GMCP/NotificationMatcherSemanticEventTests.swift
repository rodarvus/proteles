import Foundation
@testable import MudCore
import Testing

/// S0a item 4 (#82): the user's rules are a source of `SemanticEvent`s, and each
/// notification is built *from* its event. Behaviour-neutral by requirement —
/// so every parity test pins a **literal** expectation captured from the
/// pre-event behaviour and checks it against both the legacy method and the
/// event path, rather than only checking the two paths agree with each other.
@Suite("NotificationMatcher — semantic events (S0a item 4)")
struct NotificationMatcherSemanticEventTests {
    private func chat(_ channel: String, player: String, message: String) -> ChatLine {
        ChatLine(
            id: 0,
            timestamp: Date(),
            channel: channel,
            player: player,
            line: Line(id: LineID(0), text: message)
        )
    }

    /// Verbatim from `session-20260821-131406.log` — fixtures come from the
    /// corpus, not the keyboard (AARDWOLF_DATA_FEEDS.md §8).
    private let realLevelUp = "You raise a level! You are now level 100."

    // MARK: - Parity per trigger kind (literal expectations)

    @Test("keyword: legacy and event paths both produce the pre-event notification")
    func keywordParity() throws {
        let matcher = NotificationMatcher(rules: [.init(trigger: .keyword("raise a level"))])
        let expected = ProtelesNotification(title: "Match: raise a level", body: realLevelUp)
        #expect(matcher.outputNotification(for: realLevelUp) == expected)
        let event = try #require(matcher.events(forDisplayed: realLevelUp).first)
        #expect(matcher.notification(from: event) == expected)
    }

    @Test("channel: legacy and event paths both produce the pre-event notification")
    func channelParity() throws {
        let matcher = NotificationMatcher(
            notifyOnTells: false,
            notifyOnMention: false,
            rules: [.init(trigger: .channel("gossip"))]
        )
        let line = chat("gossip", player: "Wolf", message: "hello there")
        let expected = ProtelesNotification(title: "gossip", body: "Wolf: hello there")
        #expect(matcher.notification(for: line, characterName: nil) == expected)
        let event = try #require(matcher.events(forChat: line).first)
        #expect(matcher.notification(from: event) == expected)
    }

    @Test("hpBelow: legacy and event paths both produce the pre-event notification")
    func hpParity() throws {
        let matcher = NotificationMatcher(rules: [.init(trigger: .hpBelow(50))])
        let expected = ProtelesNotification(title: "Low HP", body: "HP at 40% (below 50%)")
        #expect(matcher.hpNotifications(currentPercent: 40, previousPercent: 60) == [expected])
        let event = try #require(matcher.events(forHPPercent: 40, previous: 60).first)
        #expect(matcher.notification(from: event) == expected)
    }

    @Test("questReady: legacy and event paths both produce the pre-event notification")
    func questParity() throws {
        let matcher = NotificationMatcher(rules: [.init(trigger: .questReady)])
        let expected = ProtelesNotification(title: "Quest ready", body: "You can request a new quest.")
        #expect(matcher.questReadyNotification(becameReady: true) == expected)
        let event = try #require(matcher.events(forQuestReady: true).first)
        #expect(matcher.notification(from: event) == expected)
    }

    @Test("templates render identically through the event's payload")
    func templatesRenderFromPayload() throws {
        let rule = NotificationRule(
            label: "Level!",
            trigger: .keyword("level (\\d+)"),
            regex: true,
            sound: .glass,
            titleTemplate: "Now {match}",
            bodyTemplate: "saw: {line}"
        )
        let matcher = NotificationMatcher(rules: [rule])
        let expected = ProtelesNotification(
            title: "Now 100", body: "saw: \(realLevelUp)", playSound: true, soundName: "Glass"
        )
        #expect(matcher.outputNotification(for: realLevelUp) == expected)
        let event = try #require(matcher.events(forDisplayed: realLevelUp).first)
        #expect(event.payload["match"] == "100", "regex capture must flow into the payload")
        #expect(matcher.notification(from: event) == expected)
    }

    // MARK: - What the events carry

    @Test("category and source follow the trigger kind; keyword is the weakest tier")
    func categoryAndSourcePerKind() throws {
        let keyword = NotificationRule(trigger: .keyword("raise a level"))
        let channel = NotificationRule(trigger: .channel("gossip"))
        let hp = NotificationRule(trigger: .hpBelow(50))
        let quest = NotificationRule(trigger: .questReady)
        let matcher = NotificationMatcher(
            notifyOnTells: false,
            notifyOnMention: false,
            rules: [keyword, channel, hp, quest]
        )

        let keywordEvent = try #require(matcher.events(forDisplayed: realLevelUp).first)
        #expect(keywordEvent.category == .system)
        #expect(keywordEvent.source == .pattern(rule: "user.Keyword: raise a level"))
        #expect(keywordEvent.source.durability == 2, "a keyword rule is prose matching: weakest tier")

        let gossip = chat("gossip", player: "Wolf", message: "hi")
        let channelEvent = try #require(matcher.events(forChat: gossip).first)
        #expect(channelEvent.category == .communication)
        #expect(channelEvent.source == .gmcp(package: "comm.channel"))

        let hpEvent = try #require(matcher.events(forHPPercent: 40, previous: 60).first)
        #expect(hpEvent.category == .combat)
        #expect(hpEvent.source == .gmcp(package: "char.vitals"))
        #expect(hpEvent.source.durability == 0)

        let questEvent = try #require(matcher.events(forQuestReady: true).first)
        #expect(questEvent.category == .world)
        #expect(questEvent.source == .gmcp(package: "comm.quest"))
    }

    /// `.system` is a *placeholder*: a keyword rule watches arbitrary text and
    /// the layer cannot know what it means. No consumer reads a user rule's
    /// category in V1 (D-122, wholesale). This test exists so that if someone
    /// later changes it, they do so knowingly.
    @Test("a keyword rule's category is the documented placeholder")
    func keywordCategoryIsPlaceholder() throws {
        let matcher = NotificationMatcher(rules: [.init(trigger: .keyword("level"))])
        let event = try #require(matcher.events(forDisplayed: realLevelUp).first)
        #expect(event.category == .system)
    }

    @Test("event names are rule.<uuid> and disjoint from the built-in vocabulary")
    func eventNamesAreDisjointFromVocabulary() throws {
        let rule = NotificationRule(trigger: .keyword("level"))
        let matcher = NotificationMatcher(rules: [rule])
        let event = try #require(matcher.events(forDisplayed: realLevelUp).first)
        #expect(event.name == "rule." + rule.id.uuidString)
        let collides = SemanticEventVocabulary.category(for: event.name) != nil
        #expect(!collides, "a rule event must never collide with a vocabulary name")
        // The same line also fires the vocabulary's own event, from the other source.
        #expect(SemanticClassifier.events(forDisplayedText: realLevelUp).map(\.name) == ["level_up"])
    }

    // MARK: - Guards and edges (must match the legacy path exactly)

    @Test("no enabled rules → no events; a disabled rule → no event")
    func guardsHold() {
        #expect(NotificationMatcher().events(forDisplayed: realLevelUp).isEmpty)
        let disabled = NotificationRule(trigger: .keyword("level"), enabled: false)
        let matcher = NotificationMatcher(rules: [disabled])
        #expect(matcher.events(forDisplayed: realLevelUp).isEmpty)
        #expect(matcher.outputNotification(for: realLevelUp) == nil)
        #expect(matcher.hasOutputRules == false, "the session's short-circuit stays ahead of matching")
    }

    @Test("multiple matching keyword rules → one event each; the first is the notification")
    func multipleMatchesFirstWins() throws {
        let first = NotificationRule(label: "A", trigger: .keyword("raise"))
        let second = NotificationRule(label: "B", trigger: .keyword("level"))
        let matcher = NotificationMatcher(rules: [first, second])
        let events = matcher.events(forDisplayed: realLevelUp)
        #expect(events.map(\.name) == [
            NotificationMatcher.eventName(for: first), NotificationMatcher.eventName(for: second)
        ])
        let legacy = try #require(matcher.outputNotification(for: realLevelUp))
        #expect(legacy.title == "A", "legacy path is first-match-wins, and must stay so")
        #expect(matcher.notification(from: events[0]) == legacy)
    }

    @Test("mobsay is suppressed for channel-rule events, as for notifications")
    func mobsaySuppressed() {
        let matcher = NotificationMatcher(rules: [.init(trigger: .channel("mobsay"))])
        let line = chat("mobsay", player: "", message: "A rat squeaks.")
        #expect(matcher.events(forChat: line).isEmpty)
        #expect(matcher.notification(for: line, characterName: nil) == nil)
    }

    @Test("hpBelow stays edge-triggered: already below → no event")
    func hpEdgeTriggered() {
        let matcher = NotificationMatcher(rules: [.init(trigger: .hpBelow(50))])
        #expect(matcher.events(forHPPercent: 40, previous: 30).isEmpty)
        #expect(matcher.events(forHPPercent: nil, previous: 60).isEmpty)
        let unknownPrevious = matcher.events(forHPPercent: 40, previous: nil)
        #expect(unknownPrevious.count == 1, "unknown previous counts as above")
    }

    @Test("an event whose rule was removed, or a non-rule event, builds no notification")
    func unknownEventsBuildNothing() throws {
        let rule = NotificationRule(trigger: .keyword("level"))
        let only = NotificationMatcher(rules: [rule])
        let event = try #require(only.events(forDisplayed: realLevelUp).first)
        #expect(NotificationMatcher(rules: []).notification(from: event) == nil)
        let vocabulary = try #require(SemanticClassifier.events(forDisplayedText: realLevelUp).first)
        #expect(NotificationMatcher(rules: [rule]).notification(from: vocabulary) == nil)
    }
}

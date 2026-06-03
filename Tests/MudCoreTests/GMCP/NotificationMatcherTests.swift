import Foundation
@testable import MudCore
import Testing

@Suite("NotificationMatcher — tells + mentions")
struct NotificationMatcherTests {
    private func chat(_ channel: String, player: String, message: String) -> ChatLine {
        ChatLine(
            id: 0,
            timestamp: Date(),
            channel: channel,
            player: player,
            line: Line(id: LineID(0), text: message)
        )
    }

    @Test("A tell produces a 'Tell from <player>' notification")
    func tell() {
        let matcher = NotificationMatcher()
        let note = matcher.notification(
            for: chat("tell", player: "Bob", message: "meet me at recall"),
            characterName: "Alice"
        )
        #expect(note?.title == "Tell from Bob")
        #expect(note?.body == "meet me at recall")
    }

    @Test("Tells can be disabled")
    func tellsDisabled() {
        let matcher = NotificationMatcher(notifyOnTells: false, notifyOnMention: true)
        #expect(matcher.notification(
            for: chat("tell", player: "Bob", message: "hi"), characterName: "Alice"
        ) == nil)
    }

    @Test("A channel message containing your name (whole word) is a mention")
    func mention() {
        let matcher = NotificationMatcher()
        let note = matcher.notification(
            for: chat("chat", player: "Bob", message: "hey Alice, you around?"),
            characterName: "Alice"
        )
        #expect(note?.title == "Bob mentioned you on chat")
    }

    @Test("Your name as a substring of another word is not a mention")
    func noPartialMention() {
        let matcher = NotificationMatcher()
        #expect(matcher.notification(
            for: chat("chat", player: "Bob", message: "the alarm is loud"),
            characterName: "Al"
        ) == nil)
    }

    @Test("Your own channel line doesn't notify you of a mention")
    func ownLine() {
        let matcher = NotificationMatcher()
        #expect(matcher.notification(
            for: chat("chat", player: "Alice", message: "Alice reporting in"),
            characterName: "Alice"
        ) == nil)
    }

    @Test("No mention + not a tell → no notification")
    func nothing() {
        let matcher = NotificationMatcher()
        #expect(matcher.notification(
            for: chat("gossip", player: "Bob", message: "anyone selling armour?"),
            characterName: "Alice"
        ) == nil)
    }

    // MARK: - Phase-2 custom rules (#14)

    @Test("an enabled .channel rule fires on any chat for that channel")
    func channelRule() {
        let rules = [NotificationRule(trigger: .channel("gossip"))]
        let matcher = NotificationMatcher(notifyOnTells: false, notifyOnMention: false, rules: rules)
        let note = matcher.notification(
            for: chat("gossip", player: "Bob", message: "anyone selling armour?"),
            characterName: "Alice"
        )
        #expect(note?.title == "gossip")
        #expect(note?.body == "Bob: anyone selling armour?")
        // A different channel doesn't fire.
        #expect(matcher.notification(
            for: chat("auction", player: "Bob", message: "wts sword"),
            characterName: "Alice"
        ) == nil)
    }

    @Test("an enabled .keyword rule fires on a matching output line (case-insensitive)")
    func keywordRule() {
        let rules = [NotificationRule(label: "Boss", trigger: .keyword("Lord Vyll"))]
        let matcher = NotificationMatcher(rules: rules)
        #expect(matcher.hasOutputRules)
        let note = matcher.outputNotification(for: "lord vyll has arrived from the north.")
        #expect(note?.title == "Boss") // the rule label
        #expect(note?.body == "lord vyll has arrived from the north.")
        #expect(matcher.outputNotification(for: "a goblin wanders in.") == nil)
    }

    @Test("a disabled rule never fires and isn't counted by hasOutputRules")
    func disabledRule() {
        let rules = [NotificationRule(trigger: .keyword("vyll"), enabled: false)]
        let matcher = NotificationMatcher(rules: rules)
        #expect(matcher.hasOutputRules == false)
        #expect(matcher.outputNotification(for: "vyll appears") == nil)
    }

    @Test("keyword rules don't apply to the chat path, channel rules don't apply to output")
    func pathsAreSeparate() {
        let matcher = NotificationMatcher(
            notifyOnTells: false,
            notifyOnMention: false,
            rules: [
                NotificationRule(trigger: .keyword("hello")),
                NotificationRule(trigger: .channel("gossip"))
            ]
        )
        // A keyword rule does NOT fire via the chat path...
        #expect(matcher.notification(
            for: chat("auction", player: "Bob", message: "hello there"),
            characterName: "Alice"
        ) == nil)
        // ...and a channel rule does NOT fire via the output path.
        #expect(matcher.outputNotification(for: "[gossip] Bob: hi") == nil)
    }
}

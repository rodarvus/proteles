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

    // MARK: - Phase-3 (#14): regex, sound, templates, GMCP/quest

    @Test("a regex keyword rule matches and exposes its capture to the template")
    func regexKeyword() {
        let rule = NotificationRule(
            trigger: .keyword("the (\\w+) dies"),
            regex: true,
            bodyTemplate: "{capture} slain"
        )
        let matcher = NotificationMatcher(rules: [rule])
        let note = matcher.outputNotification(for: "the dragon dies horribly")
        #expect(note?.body == "dragon slain") // capture group 1 → {capture}
        #expect(matcher.outputNotification(for: "the dragon lives") == nil)
    }

    @Test("a rule's sound + title template are applied")
    func soundAndTemplate() {
        let rule = NotificationRule(
            trigger: .keyword("vyll"),
            sound: .glass,
            titleTemplate: "Boss sighted"
        )
        let note = NotificationMatcher(rules: [rule]).outputNotification(for: "Lord Vyll arrives")
        #expect(note?.title == "Boss sighted")
        #expect(note?.playSound == true)
        #expect(note?.soundName == "Glass")
        // A silent rule plays no sound.
        let silent = NotificationRule(trigger: .keyword("x"), sound: .silent)
        #expect(NotificationMatcher(rules: [silent]).outputNotification(for: "x")?.playSound == false)
    }

    @Test("hpBelow is edge-triggered: fires on crossing below, not while already below")
    func hpBelowEdge() {
        let matcher = NotificationMatcher(rules: [NotificationRule(trigger: .hpBelow(20))])
        // Crossing 50% → 18% fires once.
        #expect(matcher.hpNotifications(currentPercent: 18, previousPercent: 50).count == 1)
        // Already below (18 → 15) does not re-fire.
        #expect(matcher.hpNotifications(currentPercent: 15, previousPercent: 18).isEmpty)
        // Unknown previous + below → fires (e.g. first vitals after login in danger).
        #expect(matcher.hpNotifications(currentPercent: 15, previousPercent: nil).count == 1)
        // Above the threshold → nothing.
        #expect(matcher.hpNotifications(currentPercent: 25, previousPercent: 50).isEmpty)
    }

    @Test("questReady fires only on the became-ready edge and only with a rule")
    func questReady() {
        let matcher = NotificationMatcher(rules: [NotificationRule(trigger: .questReady)])
        #expect(matcher.questReadyNotification(becameReady: true)?.title == "Quest ready")
        #expect(matcher.questReadyNotification(becameReady: false) == nil)
        // No quest-ready rule → nothing even on the edge.
        #expect(NotificationMatcher().questReadyNotification(becameReady: true) == nil)
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

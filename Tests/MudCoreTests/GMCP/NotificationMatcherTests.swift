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
}

import Foundation
@testable import MudCore
import Testing

@Suite("NotificationCoalescer — duplicate suppression (#14)")
struct NotificationCoalescerTests {
    private func note(_ title: String, _ body: String = "b") -> ProtelesNotification {
        ProtelesNotification(title: title, body: body)
    }

    // `shouldShow` is mutating, which can't be called inside an `#expect` macro
    // (it captures the value immutably), so each result is bound to a local.

    @Test("an identical notification is suppressed within the window, shows again after")
    func suppressesWithinWindow() {
        var coalescer = NotificationCoalescer(window: 5)
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first = coalescer.shouldShow(note("Tell from Bob"), now: base)
        let dup = coalescer.shouldShow(note("Tell from Bob"), now: base.addingTimeInterval(2))
        let afterGap = coalescer.shouldShow(note("Tell from Bob"), now: base.addingTimeInterval(8))
        #expect(first)
        #expect(!dup)
        #expect(afterGap)
    }

    @Test("distinct notifications are independent")
    func distinctPass() {
        var coalescer = NotificationCoalescer(window: 5)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let firstA = coalescer.shouldShow(note("A"), now: now)
        let firstB = coalescer.shouldShow(note("B"), now: now)
        let repeatA = coalescer.shouldShow(note("A"), now: now.addingTimeInterval(1))
        #expect(firstA)
        #expect(firstB) // different → shown
        #expect(!repeatA) // A still suppressed
    }

    @Test("a continuous burst stays collapsed (sliding window)")
    func slidingWindow() {
        var coalescer = NotificationCoalescer(window: 5)
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first = coalescer.shouldShow(note("spam"), now: base)
        #expect(first)
        // Repeats every 2s keep sliding the window → all suppressed.
        var anyShown = false
        for step in 1...5 where coalescer.shouldShow(
            note("spam"),
            now: base.addingTimeInterval(Double(step) * 2)
        ) {
            anyShown = true
        }
        #expect(!anyShown)
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("CommandHistory — recording")
struct CommandHistoryRecordingTests {
    @Test("Records commands oldest-first")
    func recordsInOrder() {
        var history = CommandHistory()
        history.record("north")
        history.record("south")
        #expect(history.entries == ["north", "south"])
    }

    @Test("Ignores empty and whitespace-only commands")
    func ignoresEmpty() {
        var history = CommandHistory()
        history.record("")
        history.record("   ")
        history.record("\t")
        #expect(history.entries.isEmpty)
    }

    @Test("Re-submitting moves a command to the most recent slot (global dedup)")
    func globalDedup() {
        var history = CommandHistory()
        history.record("north")
        history.record("look")
        history.record("north")
        #expect(history.entries == ["look", "north"])
    }

    @Test("Capacity drops the oldest entries")
    func capacityBound() {
        var history = CommandHistory(capacity: 2)
        history.record("a")
        history.record("b")
        history.record("c")
        #expect(history.entries == ["b", "c"])
    }
}

@Suite("CommandHistory — recall")
struct CommandHistoryRecallTests {
    private func seeded() -> CommandHistory {
        var history = CommandHistory()
        history.record("north")
        history.record("look")
        history.record("kill rabbit")
        return history
    }

    @Test("Up walks from newest to oldest then clamps")
    func upWalksAndClamps() {
        var history = seeded()
        #expect(history.recallPrevious(currentText: "") == "kill rabbit")
        #expect(history.recallPrevious(currentText: "kill rabbit") == "look")
        #expect(history.recallPrevious(currentText: "look") == "north")
        // Clamped at the oldest entry.
        #expect(history.recallPrevious(currentText: "north") == nil)
    }

    @Test("Up on empty history returns nil")
    func upEmpty() {
        var history = CommandHistory()
        #expect(history.recallPrevious(currentText: "") == nil)
        #expect(!history.isNavigating)
    }

    @Test("Down past the newest restores the stashed draft")
    func downRestoresDraft() {
        var history = seeded()
        #expect(history.recallPrevious(currentText: "kil") == "kill rabbit")
        // Down past newest returns to what we were typing.
        #expect(history.recallNext() == "kil")
        #expect(!history.isNavigating)
    }

    @Test("Down without navigating returns nil")
    func downWhenNotNavigating() {
        var history = seeded()
        #expect(history.recallNext() == nil)
    }

    @Test("Up then Down walks back to a newer entry")
    func upThenDown() {
        var history = seeded()
        _ = history.recallPrevious(currentText: "") // kill rabbit
        _ = history.recallPrevious(currentText: "kill rabbit") // look
        #expect(history.recallNext() == "kill rabbit")
    }

    @Test("Recording resets navigation")
    func recordResetsNavigation() {
        var history = seeded()
        _ = history.recallPrevious(currentText: "")
        #expect(history.isNavigating)
        history.record("flee")
        #expect(!history.isNavigating)
    }
}

@Suite("CommandHistory — completion")
struct CommandHistoryCompletionTests {
    private func seeded() -> CommandHistory {
        var history = CommandHistory()
        for command in ["kill rabbit", "kill rat", "look", "kick door"] {
            history.record(command)
        }
        return history
    }

    @Test("Prefix matches most-recent first")
    func prefixMatch() {
        let history = seeded()
        #expect(history.completions(for: "kill") == ["kill rat", "kill rabbit"])
    }

    @Test("Empty prefix yields nothing")
    func emptyPrefix() {
        let history = seeded()
        #expect(history.completions(for: "").isEmpty)
        #expect(history.completions(for: "   ").isEmpty)
    }

    @Test("An exact full-line match is not offered as its own completion")
    func noSelfCompletion() {
        let history = seeded()
        #expect(!history.completions(for: "look").contains("look"))
    }

    @Test("Matching is case-insensitive but preserves stored casing")
    func caseInsensitive() {
        var history = CommandHistory()
        history.record("Kill Rabbit")
        #expect(history.completions(for: "kill") == ["Kill Rabbit"])
    }

    @Test("Communication commands are excluded from completion")
    func excludesCommunication() {
        var history = CommandHistory()
        history.record("tell bob hello there")
        history.record("reply see you soon")
        history.record("telekinesis")
        // "tel" would match the tell/reply-adjacent words, but tell/reply
        // are excluded; telekinesis (a real command) is offered.
        #expect(history.completions(for: "tel") == ["telekinesis"])
    }

    @Test("isExcludedFromCompletion keys off the first word, case-insensitively")
    func exclusionFirstWord() {
        let history = CommandHistory()
        #expect(history.isExcludedFromCompletion("tell bob hi"))
        #expect(history.isExcludedFromCompletion("CLAN hello"))
        #expect(!history.isExcludedFromCompletion("kill rabbit"))
    }

    @Test("A custom exclusion set overrides the default")
    func customExclusions() {
        var history = CommandHistory(completionExclusions: ["secret"])
        history.record("secret password")
        history.record("tell bob hi")
        #expect(history.completions(for: "se").isEmpty)
        // "tell" isn't excluded under the custom set.
        #expect(history.completions(for: "tell") == ["tell bob hi"])
    }
}

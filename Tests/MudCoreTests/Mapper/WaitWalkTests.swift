import Foundation
@testable import MudCore
import Testing

/// ``WaitWalk`` — the pure split of a mapper speedwalk / custom-exit command
/// into command chunks + timed pauses, ported from the Aardwolf mapper's
/// `ExecuteWithWaits`. Fixtures are real rows from a live `Aardwolf.db` exits
/// table so the parse matches what the user's map actually stores.
@Suite("Mapper — WaitWalk (cexit wait() parsing)")
struct WaitWalkTests {
    /// The canonical hunt-walk that leaked `wait(1)` to the MUD: three hunts,
    /// each followed by a one-second pause. `wait(1)` must NEVER appear as a
    /// command chunk.
    @Test("A hunt-walk splits into alternating hunt commands and 1s pauses")
    func huntWalkSplits() {
        let steps = WaitWalk.steps(
            from: "hunt crystal;wait(1);hunt crystal;wait(1);hunt crystal;wait(1)"
        )
        #expect(steps == [
            .commands("hunt crystal"),
            .wait(seconds: 1),
            .commands("hunt crystal"),
            .wait(seconds: 1),
            .commands("hunt crystal"),
            .wait(seconds: 1)
        ])
        // The literal that the MUD rejected must not survive as a command.
        for case .commands(let chunk) in steps {
            #expect(!chunk.contains("wait("), "a wait token leaked into a command: \(chunk)")
        }
    }

    /// A command with no `wait()` is a single chunk (a normal segment passes
    /// straight through the same parser).
    @Test("A plain command with no wait is one chunk")
    func plainCommand() {
        #expect(WaitWalk.steps(from: "run 3n2e") == [.commands("run 3n2e")])
        #expect(!WaitWalk.containsWait("run 3n2e"))
        #expect(WaitWalk.containsWait("hunt crystal;wait(1)"))
    }

    /// Fractional and multi-digit waits parse (real rows use `0.5`, `3.5`, `12`).
    @Test("Fractional and multi-digit waits parse to seconds")
    func fractionalWaits() {
        #expect(WaitWalk.steps(from: "hunt horath;wait(0.5);exit;wait(0.5)") == [
            .commands("hunt horath"),
            .wait(seconds: 0.5),
            .commands("exit"),
            .wait(seconds: 0.5)
        ])
        #expect(WaitWalk.steps(from: "say I wish to see the genie;wait(3.5)") == [
            .commands("say I wish to see the genie"),
            .wait(seconds: 3.5)
        ])
        #expect(WaitWalk.steps(from: "say I love you;wait(12)") == [
            .commands("say I love you"),
            .wait(seconds: 12)
        ])
    }

    /// A leading `wait()` (no command before it) emits the pause first, then
    /// the trailing command — `wait(1);mh vlad;wait(1)`.
    @Test("A leading wait emits the pause before the first command")
    func leadingWait() {
        #expect(WaitWalk.steps(from: "wait(1);mh vlad;wait(1)") == [
            .wait(seconds: 1),
            .commands("mh vlad"),
            .wait(seconds: 1)
        ])
    }

    /// `;`-stacked commands inside a chunk are preserved (the command surface
    /// splits them, mirroring `Execute`) — only the wait tokens are extracted.
    @Test("Stacked commands inside a chunk are preserved between waits")
    func stackedChunk() {
        #expect(
            WaitWalk.steps(from: "buy Maine;run wn;board;o e;e;giv Maine conductor;wait(4)") == [
                .commands("buy Maine;run wn;board;o e;e;giv Maine conductor"),
                .wait(seconds: 4)
            ]
        )
    }

    /// An empty command yields no steps (the reference `Execute("")` is a no-op).
    @Test("An empty command yields no steps")
    func emptyCommand() {
        #expect(WaitWalk.steps(from: "").isEmpty)
    }
}

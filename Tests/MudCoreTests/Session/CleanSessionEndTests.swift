import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — clean-session-end handler (#42)")
struct CleanSessionEndTests {
    /// A tiny mutable flag the @Sendable handler can flip; reads/writes are
    /// sequential (handler runs on the actor, test awaits), so unchecked is fine.
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    @Test("disconnect() fires the handler (intentional end)")
    func disconnectFires() async {
        let controller = SessionController()
        let flag = Flag()
        await controller.setCleanSessionEndHandler { flag.fired = true }
        await controller.disconnect()
        #expect(flag.fired)
    }

    @Test("a quit command fires the handler; ordinary commands don't")
    func quitFiresOrdinaryDoesnt() async {
        let controller = SessionController()
        let flag = Flag()
        await controller.setCleanSessionEndHandler { flag.fired = true }

        // Ordinary command (no connection needed — `expectsCleanClose` is set at
        // the top of send(), before any I/O).
        try? await controller.send("north")
        #expect(!flag.fired)

        try? await controller.send("quit")
        #expect(flag.fired)
    }
}

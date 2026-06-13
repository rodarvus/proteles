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

    @Test("typing quit alone does NOT fire the handler — the server may refuse it")
    func quitAloneDoesNotFire() async {
        let controller = SessionController()
        let flag = Flag()
        await controller.setCleanSessionEndHandler { flag.fired = true }

        // Ordinary command: never a clean end.
        try? await controller.send("north")
        #expect(!flag.fired)

        // `quit` must NOT drop the resume breadcrumb on its own: Aardwolf can
        // refuse it (combat, confirmation) and leave you connected. Only an
        // actual prompt server close is a clean logout (covered by the loopback
        // test). Regression guard for #42 — typing quit used to clear the
        // breadcrumb immediately, losing resume when the quit was refused and
        // the app was closed before the next heartbeat.
        try? await controller.send("quit")
        #expect(!flag.fired)
    }
}

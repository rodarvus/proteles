import Foundation
@testable import MudCore
import Testing

/// Anti-idle keep-alive: Aardwolf disconnects a connected-but-quiet session
/// ("Idle time exceeded — see you when you get back!"). MUSHclient avoids the
/// link dropping via TCP keepalive; we add that (``NetworkConnection``) plus an
/// application-level telnet `IAC NOP` so Aardwolf's *command*-idle timer is kept
/// alive too. These cover the NOP bytes, the pure timing decision, and that the
/// loop actually transmits a NOP over a quiet, connected session.
@Suite("SessionController — anti-idle keep-alive", .serialized)
struct KeepAliveTests {
    @Test("The keep-alive probe is a telnet IAC NOP")
    func nopBytes() {
        #expect(SessionController.telnetNOP == [0xFF, 0xF1])
    }

    @Test("shouldSendKeepAlive fires only once the idle threshold is reached")
    func idleDecision() {
        let now = Date()
        #expect(SessionController.shouldSendKeepAlive(
            now: now, lastActivity: now.addingTimeInterval(-130), interval: 120
        ))
        #expect(!SessionController.shouldSendKeepAlive(
            now: now, lastActivity: now.addingTimeInterval(-10), interval: 120
        ))
    }

    @Test("A quiet connected session transmits a NOP after the interval")
    func quietSessionSendsNOP() async throws {
        let conn = InMemoryConnection()
        // 0.1s interval so the loop fires quickly in-test.
        let controller = SessionController(keepAliveInterval: 0.1, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Don't send anything; wait past a couple of intervals for the NOP.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var sawNOP = false
        while ContinuousClock.now < deadline {
            if conn.sentBytes.contains(where: { $0 == SessionController.telnetNOP }) {
                sawNOP = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawNOP, "no IAC NOP was sent on a quiet connected session: \(conn.sentBytes)")
        await controller.disconnect()
    }
}

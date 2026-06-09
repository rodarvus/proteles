import Foundation
@testable import MudCore
import Testing

/// Live end-to-end check of ``WebSocketConnection`` against Aardwolf's real
/// gateway. Network-dependent, so it runs ONLY when PROTELES_LIVE_WS is set
/// (never on CI / normal runs).
@Suite(
    "WebSocketConnection — live gateway",
    .enabled(if: ProcessInfo.processInfo.environment["PROTELES_LIVE_WS"] != nil)
)
struct WebSocketConnectionLiveTests {
    @Test("connects, sends a name, and decodes the password prompt (multi-frame)")
    func liveLoginPrompt() async throws {
        let conn = WebSocketConnection()
        try await conn.connect(to: .init(host: "aardmud.org", port: 4010), timeout: .seconds(12))
        // After connect (bridge up), the banner arrived; submit a name and we
        // must decode the *second* independent frame — the password prompt.
        try await conn.send([UInt8]("rodarvus\r\n".utf8))
        var got = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        for await chunk in conn.bytes {
            got += String(bytes: chunk, encoding: .isoLatin1) ?? ""
            if got.contains("Password:") || ContinuousClock.now > deadline { break }
        }
        await conn.disconnect()
        #expect(got.contains("Aardwolf"), "banner missing")
        #expect(got.contains("Password:"), "password prompt (frame 2) not decoded")
    }
}

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
    @Test("connects, bridges, and delivers the inflated telnet banner")
    func liveBanner() async throws {
        let conn = WebSocketConnection()
        try await conn.connect(to: .init(host: "aardmud.org", port: 4000), timeout: .seconds(12))
        // First inbound chunk should be the inflated telnet banner.
        var got = ""
        for await chunk in conn.bytes {
            got += String(bytes: chunk, encoding: .isoLatin1) ?? ""
            if got.contains("Aardwolf") { break }
        }
        await conn.disconnect()
        #expect(got.contains("Aardwolf"), "banner not received; got \(got.count) bytes")
    }
}

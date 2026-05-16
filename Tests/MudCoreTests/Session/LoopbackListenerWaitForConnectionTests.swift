@testable import MudCore
import Testing

@Suite("LoopbackListener — waitForConnection", .serialized)
struct LoopbackListenerWaitForConnectionTests {
    @Test("waitForConnection completes once a client is connected")
    func waitForConnectionCompletes() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let client = NetworkConnection()
        try await client.connect(to: .init(host: "127.0.0.1", port: port))

        // This is the suspicious call — should resume promptly.
        await listener.waitForConnection()

        await client.disconnect()
    }
}

import Foundation
@testable import MudCore
import Testing

// Autoreconnect behaviour. Uses tiny backoff delays so the suite stays
// fast, and the LoopbackListener's `dropConnection()` to simulate a
// server-side close that keeps the port open for the client's retry.

@Suite("SessionController — autoreconnect", .serialized)
struct SessionControllerAutoreconnectTests {
    private func fastPolicy(maxAttempts: Int) -> ReconnectPolicy {
        ReconnectPolicy(
            isEnabled: true,
            maxAttempts: maxAttempts,
            baseDelay: .milliseconds(20),
            maxDelay: .milliseconds(40),
            multiplier: 2
        )
    }

    /// Collect states until `predicate` holds, then return what we saw.
    private func observe(
        _ controller: SessionController,
        until predicate: @escaping @Sendable ([SessionController.State]) -> Bool
    ) -> Task<[SessionController.State], Never> {
        Task {
            var seen: [SessionController.State] = []
            for await newState in controller.connectionStates {
                seen.append(newState)
                if predicate(seen) { break }
            }
            return seen
        }
    }

    @Test("Reconnects to the same endpoint after a server-side drop")
    func reconnectsAfterDrop() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController(reconnectPolicy: fastPolicy(maxAttempts: 10))
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        // Server closes the current connection but keeps listening.
        await listener.dropConnection()

        // The controller should re-establish a fresh connection.
        await listener.waitForConnection()

        // Verify the new session is live by pushing a line through it.
        let stream = await controller.scrollbackStore.subscribe()
        try await listener.send(Array("back online\n".utf8))
        var line: Line?
        for await received in stream {
            line = received
            break
        }
        #expect(line?.text == "back online")

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Gives up after maxAttempts when the endpoint stays dead")
    func givesUpAfterMaxAttempts() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController(reconnectPolicy: fastPolicy(maxAttempts: 2))
        let observer = observe(controller) { seen in
            seen.contains(.connected) && seen.last == .disconnected
        }

        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        // Tear the whole listener down so the port is closed; every
        // reconnect attempt will fail and the controller must give up.
        await listener.stop()

        let seen = await observer.value
        #expect(seen.contains(.connected))
        #expect(seen.last == .disconnected)
        let finalState = await controller.state
        #expect(finalState == .disconnected)
    }

    @Test("A user-initiated disconnect does not autoreconnect")
    func userDisconnectDoesNotReconnect() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController(reconnectPolicy: fastPolicy(maxAttempts: 10))
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        await controller.disconnect()

        // Give any (erroneous) reconnect loop time to fire.
        try await Task.sleep(for: .milliseconds(150))
        let finalState = await controller.state
        #expect(finalState == .disconnected)

        await listener.stop()
    }
}

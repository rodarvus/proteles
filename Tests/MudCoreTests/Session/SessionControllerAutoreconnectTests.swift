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

    @Test("A quit command makes the ensuing server close a clean logout (no reconnect)")
    func quitSuppressesReconnect() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController(reconnectPolicy: fastPolicy(maxAttempts: 10))
        let observer = observe(controller) { seen in
            seen.contains(.connected) && seen.last == .disconnected
        }

        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        // User logs out; the server then closes its side.
        try await controller.send("quit")
        await listener.stop()

        let seen = await observer.value
        #expect(seen.contains(.connected))
        #expect(seen.last == .disconnected)

        // No reconnect should have started.
        try await Task.sleep(for: .milliseconds(200))
        let finalState = await controller.state
        #expect(finalState == .disconnected)
    }

    @Test("quit + prompt server close fires the clean-end handler; refused quit doesn't (#42)")
    func quitClearsBreadcrumbOnlyOnPromptClose() async throws {
        // Case A: quit, then the server closes → clean logout → handler fires.
        let listenerA = LoopbackListener()
        let portA = try await listenerA.start()
        let controllerA = SessionController(reconnectPolicy: fastPolicy(maxAttempts: 10))
        let flagA = CleanEndFlag()
        await controllerA.setCleanSessionEndHandler { flagA.fired = true }
        try await controllerA.connect(to: .init(host: "127.0.0.1", port: portA))
        await listenerA.waitForConnection()
        try await controllerA.send("quit")
        await listenerA.stop() // server closes its side
        try await Task.sleep(for: .milliseconds(200))
        #expect(flagA.fired, "a prompt close after quit is a clean logout")

        // Case B: quit, but the connection stays up (Aardwolf refused it) →
        // handler must NOT fire, so the resume breadcrumb survives.
        let listenerB = LoopbackListener()
        let portB = try await listenerB.start()
        let controllerB = SessionController(reconnectPolicy: fastPolicy(maxAttempts: 10))
        let flagB = CleanEndFlag()
        await controllerB.setCleanSessionEndHandler { flagB.fired = true }
        try await controllerB.connect(to: .init(host: "127.0.0.1", port: portB))
        await listenerB.waitForConnection()
        try await controllerB.send("quit")
        try await Task.sleep(for: .milliseconds(200)) // no close
        #expect(!flagB.fired, "a refused quit (no close) must keep the breadcrumb")
        await listenerB.stop()
    }

    @Test("`quit quit` (force-logout) makes the ensuing close clean — no reconnect")
    func quitQuitSuppressesReconnect() async throws {
        // Live repro (session-20260618-170947): holding unsaveable items, the
        // user force-quit with `quit quit`; the server logged them out and
        // closed, but the client autoreconnected and re-sent the character
        // name. Only the exact string `quit` was recognised as a logout, so
        // the force-quit form fell through to the drop→reconnect path.
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController(reconnectPolicy: fastPolicy(maxAttempts: 10))
        let observer = observe(controller) { seen in
            seen.contains(.connected) && seen.last == .disconnected
        }

        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        try await controller.send("quit quit")
        await listener.stop() // server closes its side after the force-quit

        let seen = await observer.value
        #expect(seen.contains(.connected))
        #expect(seen.last == .disconnected)

        // No reconnect should have started.
        try await Task.sleep(for: .milliseconds(200))
        let finalState = await controller.state
        #expect(finalState == .disconnected)
    }

    @Test("isLogoutQuit recognises Aardwolf's logout forms, and only those")
    func logoutQuitClassification() {
        // Forms that actually close the connection.
        #expect(SessionController.isLogoutQuit("quit"))
        #expect(SessionController.isLogoutQuit("quit quit"))
        // Tolerate case and stray whitespace from the input box.
        #expect(SessionController.isLogoutQuit("  Quit  "))
        #expect(SessionController.isLogoutQuit("Quit  Quit"))
        // Forms that do NOT log you out — they must keep autoreconnect armed.
        #expect(!SessionController.isLogoutQuit("quit check"))
        #expect(!SessionController.isLogoutQuit("quit haha"))
        #expect(!SessionController.isLogoutQuit("look"))
        #expect(!SessionController.isLogoutQuit(""))
    }
}

/// Mutable flag the @Sendable clean-end handler flips; the test awaits the
/// actor between writes, so unchecked is fine.
private final class CleanEndFlag: @unchecked Sendable {
    var fired = false
}

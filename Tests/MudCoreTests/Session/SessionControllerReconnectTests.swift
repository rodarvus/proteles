import Foundation
@testable import MudCore
import Testing

// Regression coverage for the connection life cycle: a SessionController
// must survive disconnect → reconnect (the byte stream used to be a
// single AsyncStream finished forever on the first disconnect, so a
// second session silently delivered nothing), and it must surface a
// remote-initiated close as `.disconnected`.

@Suite("SessionController — reconnect & remote close", .serialized)
struct SessionControllerReconnectTests {
    @Test("A second session after disconnect processes its inbound bytes")
    func reconnectDeliversBytes() async throws {
        let controller = SessionController()

        // First session.
        let listenerA = LoopbackListener()
        let portA = try await listenerA.start()
        try await controller.connect(to: .init(host: "127.0.0.1", port: portA))
        await listenerA.waitForConnection()
        let streamA = await controller.scrollbackStore.subscribe()
        try await listenerA.send(Array("first\n".utf8))
        var firstLine: Line?
        for await line in streamA {
            firstLine = line
            break
        }
        #expect(firstLine?.text == "first")

        await controller.disconnect()
        await listenerA.stop()

        // Second session on a fresh listener — used to deliver nothing
        // because the byte stream had been finished permanently.
        let listenerB = LoopbackListener()
        let portB = try await listenerB.start()
        try await controller.connect(to: .init(host: "127.0.0.1", port: portB))
        await listenerB.waitForConnection()
        let streamB = await controller.scrollbackStore.subscribe()
        try await listenerB.send(Array("second\n".utf8))
        var secondLine: Line?
        for await line in streamB {
            secondLine = line
            break
        }
        #expect(secondLine?.text == "second")

        await controller.disconnect()
        await listenerB.stop()
    }

    @Test("Connecting while already connected throws alreadyConnected")
    func doubleConnectThrows() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        do {
            try await controller.connect(to: .init(host: "127.0.0.1", port: port))
            Issue.record("expected alreadyConnected")
        } catch let error as SessionController.SessionError {
            #expect(error == .alreadyConnected)
        }

        await controller.disconnect()
        await listener.stop()
    }

    @Test("A remote close surfaces as .disconnected on the durable stream")
    func remoteCloseDisconnects() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        let observer = Task {
            var seen: [SessionController.State] = []
            for await newState in controller.connectionStates {
                seen.append(newState)
                if newState == .disconnected, seen.contains(.connected) {
                    break
                }
            }
            return seen
        }

        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        // Server tears its side down; the client must notice.
        await listener.stop()

        let seen = await observer.value
        #expect(seen.contains(.connected))
        #expect(seen.last == .disconnected)

        // The controller is back to a clean slate, so a fresh connect is
        // permitted (it would throw alreadyConnected if teardown leaked).
        let nextState = await controller.state
        #expect(nextState == .disconnected)
    }
}

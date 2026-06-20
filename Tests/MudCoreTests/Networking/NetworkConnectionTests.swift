import Foundation
@testable import MudCore
import Testing

// MARK: - Validation (no network)

@Suite("NetworkConnection — validation")
struct NetworkConnectionValidationTests {
    @Test("Initial state is disconnected")
    func initialStateIsDisconnected() async {
        let connection = NetworkConnection()
        let state = await connection.state
        #expect(state == .disconnected)
    }

    @Test("Invalid port (0) throws invalidPort")
    func invalidPortThrows() async {
        let connection = NetworkConnection()
        do {
            try await connection.connect(
                to: .init(host: "127.0.0.1", port: 0)
            )
            Issue.record("connect should have thrown")
        } catch let error as NetworkConnection.ConnectionError {
            #expect(error == .invalidPort(0))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Send when not connected throws notConnected")
    func sendWhenNotConnectedThrows() async {
        let connection = NetworkConnection()
        do {
            try await connection.send([0x41])
            Issue.record("send should have thrown")
        } catch let error as NetworkConnection.ConnectionError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Disconnect on disconnected actor is a no-op")
    func disconnectIdempotent() async {
        let connection = NetworkConnection()
        await connection.disconnect()
        let state = await connection.state
        #expect(state == .disconnected)
    }

    @Test("Connecting to an unreachable host times out with .timedOut")
    func connectTimesOut() async {
        // 192.0.2.1 is TEST-NET-1 (RFC 5737) — reserved, never
        // routed, so the SYN gets no response and NWConnection never
        // reaches .ready. A short timeout should fire .timedOut
        // rather than hang.
        let connection = NetworkConnection()
        let start = ContinuousClock.now
        do {
            try await connection.connect(
                to: .init(host: "192.0.2.1", port: 9999),
                timeout: .milliseconds(400)
            )
            Issue.record("connect should have timed out")
        } catch let error as NetworkConnection.ConnectionError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        // The real contract is the `.timedOut` error above — the connection
        // fails fast rather than hanging. We also bound the wall clock purely as
        // an anti-hang guard: under `swift test --parallel` on CI the timeout
        // Task can be starved badly (observed >11s for a 400ms timeout — past
        // even the 10s default), so a tight bound flakes and can't reliably
        // distinguish the short timeout from the default. The generous ceiling
        // only catches a genuine never-resolving hang.
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(30))

        let state = await connection.state
        #expect(state == .disconnected)
    }
}

// MARK: - Loopback integration

@Suite("NetworkConnection — loopback integration", .serialized)
struct NetworkConnectionLoopbackTests {
    @Test("Connect, send, receive echo, disconnect")
    func loopbackEcho() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let connection = NetworkConnection()
        try await connection.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        let connectedState = await connection.state
        #expect(connectedState == .connected)

        let payload: [UInt8] = [0x68, 0x65, 0x6C, 0x6C, 0x6F] // "hello"
        try await connection.send(payload)

        // Wait for the listener to receive what we sent.
        var receivedByListener: [UInt8] = []
        for await chunk in listener.received {
            receivedByListener.append(contentsOf: chunk)
            if receivedByListener.count >= payload.count { break }
        }
        #expect(receivedByListener == payload)

        // Have the listener push something back, then verify it arrives
        // on the connection's bytes stream.
        let reply: [UInt8] = [0x77, 0x6F, 0x72, 0x6C, 0x64] // "world"
        try await listener.send(reply)

        var receivedByClient: [UInt8] = []
        for await chunk in connection.bytes {
            receivedByClient.append(contentsOf: chunk)
            if receivedByClient.count >= reply.count { break }
        }
        #expect(receivedByClient == reply)

        await connection.disconnect()
        // Drain state stream to observe the transition to disconnected.
        var observed: [NetworkConnection.State] = []
        for await new in connection.states {
            observed.append(new)
            if new == .disconnected { break }
        }
        #expect(observed.contains(.disconnected))
    }

    @Test("Connect twice throws alreadyActive on second call")
    func connectTwiceThrows() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let connection = NetworkConnection()
        try await connection.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        do {
            try await connection.connect(
                to: .init(host: "127.0.0.1", port: port)
            )
            Issue.record("second connect should have thrown")
        } catch let error as NetworkConnection.ConnectionError {
            #expect(error == .alreadyActive)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        await connection.disconnect()
    }

    @Test("State stream reports connecting then connected then disconnected")
    func stateStreamReportsTransitions() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let connection = NetworkConnection()

        // Begin observing state in a Task before we connect, so we
        // capture the .connecting transition.
        let observer = Task {
            var observed: [NetworkConnection.State] = []
            for await new in connection.states {
                observed.append(new)
                if new == .disconnected, observed.contains(.connected) {
                    break
                }
            }
            return observed
        }

        try await connection.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await connection.disconnect()

        let observed = await observer.value
        #expect(observed.contains(.connecting))
        #expect(observed.contains(.connected))
        #expect(observed.contains(.disconnected))
    }
}

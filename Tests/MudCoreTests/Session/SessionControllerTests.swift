import Foundation
@testable import MudCore
import Testing

// SessionController integration tests. They use the same in-process
// LoopbackListener fixture that NetworkConnection's tests rely on, so
// they exercise the real Network.framework stack end-to-end.

@Suite("SessionController — validation")
struct SessionControllerValidationTests {
    @Test("Initial state is disconnected")
    func initialStateIsDisconnected() async {
        let controller = SessionController()
        let state = await controller.state
        #expect(state == .disconnected)
    }

    @Test("send() throws notConnected before connect")
    func sendBeforeConnectThrows() async {
        let controller = SessionController()
        do {
            try await controller.send("look")
            Issue.record("expected send to throw")
        } catch let error as SessionController.SessionError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Suite("SessionController — pipeline integration", .serialized)
struct SessionControllerPipelineTests {
    @Test("Outbound: send() writes `command\\r\\n` to the wire")
    func sendAppendsCRLF() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )

        try await controller.send("look")

        var received: [UInt8] = []
        let expected: [UInt8] = Array("look\r\n".utf8)
        for await chunk in listener.received {
            received.append(contentsOf: chunk)
            if received.count >= expected.count { break }
        }
        #expect(received == expected)

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Inbound: plain text becomes a Line in the scrollback store")
    func inboundPlainTextAppears() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        let storeStream = await controller.scrollbackStore.subscribe()
        try await listener.send(Array("Welcome to Aardwolf!\n".utf8))

        var firstLine: Line?
        for await line in storeStream {
            firstLine = line
            break
        }
        let captured = try #require(firstLine)
        #expect(captured.text == "Welcome to Aardwolf!")
        #expect(captured.runs.isEmpty)

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Inbound: ANSI-styled text yields a Line with styled runs")
    func inboundANSITextProducesStyledRuns() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        let storeStream = await controller.scrollbackStore.subscribe()
        let payload = "\u{1B}[31mred\u{1B}[0m\n"
        try await listener.send(Array(payload.utf8))

        var firstLine: Line?
        for await line in storeStream {
            firstLine = line
            break
        }
        let captured = try #require(firstLine)
        #expect(captured.text == "red")
        #expect(captured.runs == [
            StyledRun(
                utf16Range: 0..<3,
                style: StyleAttributes(foreground: .named(.red))
            )
        ])

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Telnet: WILL MXP from server gets a DONT MXP back")
    func telnetWillIsRefused() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        let serverWillMXP: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.mxp
        ]
        try await listener.send(serverWillMXP)

        let expectedReply: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.dont, TelnetOption.mxp
        ]
        var received: [UInt8] = []
        for await chunk in listener.received {
            received.append(contentsOf: chunk)
            if received.count >= expectedReply.count { break }
        }
        #expect(received == expectedReply)

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Telnet: DO TTYPE from server gets a WILL TTYPE back (MTTS)")
    func telnetDoIsRefused() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        let serverDoTTYPE: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.do, TelnetOption.terminalType
        ]
        try await listener.send(serverDoTTYPE)

        let expectedReply: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.terminalType
        ]
        var received: [UInt8] = []
        for await chunk in listener.received {
            received.append(contentsOf: chunk)
            if received.count >= expectedReply.count { break }
        }
        #expect(received == expectedReply)

        await controller.disconnect()
        await listener.stop()
    }

    // Note: a "reconnect after disconnect" integration test was tried
    // here but is flaky because `connection.disconnect()` returns with
    // the underlying `NWConnection` still in `.cancelling`, and the
    // race between that and a fresh `.connect()` is awkward to wait on
    // without leaking implementation details. Parser-reset semantics
    // are covered by the unit-level `reset()` tests on TelnetProcessor,
    // ANSIParser, and LineBuilder; the integration angle reappears
    // in Phase 3 when SessionController grows an exposed reconnect
    // affordance (PLAN.md §8.4).
}

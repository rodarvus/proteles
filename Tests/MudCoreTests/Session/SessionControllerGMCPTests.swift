import Foundation
@testable import MudCore
import Testing

// End-to-end GMCP: the server enables GMCP, the controller replies DO and
// sends its handshake, and an inbound Char.Vitals subnegotiation lands in
// the GMCP state store.

private actor ByteSink {
    private(set) var bytes: [UInt8] = []
    func append(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
    }

    func snapshot() -> [UInt8] {
        bytes
    }
}

@Suite("SessionController — GMCP", .serialized)
struct SessionControllerGMCPTests {
    private func drain(_ listener: LoopbackListener, into sink: ByteSink) -> Task<Void, Never> {
        Task {
            for await chunk in listener.received {
                await sink.append(chunk)
            }
        }
    }

    private func waitFor(
        _ needle: [UInt8],
        in sink: ByteSink,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await Data(sink.snapshot()).range(of: Data(needle)) != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("Server WILL GMCP → client replies DO GMCP and sends the handshake")
    func sendsHandshakeOnEnable() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let sink = ByteSink()
        let drainTask = drain(listener, into: sink)

        let controller = SessionController()
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        try await listener.send([TelnetCommand.iac, TelnetCommand.will, TelnetOption.gmcp])

        // DO GMCP reply.
        let doGMCP: [UInt8] = [TelnetCommand.iac, TelnetCommand.do, TelnetOption.gmcp]
        #expect(await waitFor(doGMCP, in: sink))
        // Handshake: the Core.Supports.Set packet must go out.
        let supports = Array(#"Core.Supports.Set [ "Char 1", "Comm 1", "Room 1" ]"#.utf8)
        #expect(await waitFor(supports, in: sink))

        await controller.disconnect()
        await listener.stop()
        drainTask.cancel()
    }

    @Test("Inbound Char.Vitals subnegotiation updates the GMCP state store")
    func inboundVitalsUpdatesState() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        let payload = Array(#"Char.Vitals {"hp":1234,"mana":900,"moves":500}"#.utf8)
        var subneg: [UInt8] = [TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp]
        subneg += payload
        subneg += [TelnetCommand.iac, TelnetCommand.se]
        try await listener.send(subneg)

        // Poll the store until the vitals arrive.
        var vitals: CharVitals?
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            vitals = await controller.gmcpState.state.vitals
            if vitals != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(vitals == CharVitals(hp: 1234, mana: 900, moves: 500))

        await controller.disconnect()
        await listener.stop()
    }
}

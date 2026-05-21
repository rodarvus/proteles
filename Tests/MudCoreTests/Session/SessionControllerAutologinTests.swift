import Foundation
@testable import MudCore
import Testing

// Prompt-driven ("Diku-style") autologin, exercised end-to-end against
// the in-process LoopbackListener so the real Network.framework stack
// and the LinePipeline drive the state machine.
//
// `listener.received` is a single-consumer stream, so each test starts
// one drain task that accumulates every byte the server receives into a
// `ByteSink`; assertions poll the sink rather than racing the stream.

/// Thread-safe accumulator for bytes the loopback server receives.
private actor ByteSink {
    private(set) var bytes: [UInt8] = []
    func append(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
    }

    func snapshot() -> [UInt8] {
        bytes
    }
}

@Suite("SessionController — autologin", .serialized)
struct SessionControllerAutologinTests {
    private func drain(_ listener: LoopbackListener, into sink: ByteSink) -> Task<Void, Never> {
        Task {
            for await chunk in listener.received {
                await sink.append(chunk)
            }
        }
    }

    /// Poll `sink` until it contains `needle` (UTF-8) or the timeout
    /// elapses. Records an issue on timeout.
    private func waitFor(
        _ needle: String,
        in sink: ByteSink,
        timeout: Duration = .seconds(2)
    ) async -> [UInt8] {
        let target = Array(needle.utf8)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let snapshot = await sink.snapshot()
            if snapshot.contains(subsequence: target) { return snapshot }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = await sink.snapshot()
        Issue.record("timed out before seeing \(needle.debugDescription)")
        return snapshot
    }

    @Test("Sends username then password when the prompts appear")
    func fullSequence() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let sink = ByteSink()
        let drainTask = drain(listener, into: sink)

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port),
            autologin: AutologinPlan(username: "Conan", password: "cimmeria")
        )
        await listener.waitForConnection()

        // The name prompt arrives WITHOUT a trailing newline — it lives
        // in the pipeline's pending buffer, never emitted as a Line.
        try await listener.send(Array("What be thy name, adventurer? ".utf8))
        let afterName = await waitFor("Conan\r\n", in: sink)
        #expect(afterName.contains(subsequence: Array("Conan\r\n".utf8)))

        // Server flushes the name prompt with a newline, then shows the
        // (also un-terminated) password prompt.
        try await listener.send(Array("\r\nPassword: ".utf8))
        let afterPass = await waitFor("cimmeria\r\n", in: sink)
        #expect(afterPass.contains(subsequence: Array("cimmeria\r\n".utf8)))

        await controller.disconnect()
        await listener.stop()
        drainTask.cancel()
    }

    @Test("With no password, sends the username but never a password")
    func usernameOnly() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let sink = ByteSink()
        let drainTask = drain(listener, into: sink)

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port),
            autologin: AutologinPlan(username: "Conan", password: "")
        )
        await listener.waitForConnection()

        try await listener.send(Array("What be thy name, adventurer? ".utf8))
        _ = await waitFor("Conan\r\n", in: sink)

        // Even when the password prompt arrives, nothing more is sent.
        try await listener.send(Array("\r\nPassword: ".utf8))
        try await Task.sleep(for: .milliseconds(300))
        let received = await sink.snapshot()
        #expect(received == Array("Conan\r\n".utf8))

        await controller.disconnect()
        await listener.stop()
        drainTask.cancel()
    }

    @Test("No autologin plan sends nothing on connect")
    func noPlanSendsNothing() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let sink = ByteSink()
        let drainTask = drain(listener, into: sink)

        let controller = SessionController()
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        try await listener.send(Array("What be thy name, adventurer? ".utf8))
        try await Task.sleep(for: .milliseconds(250))
        #expect(await sink.snapshot().isEmpty)

        // A manual command still goes out — autologin being off doesn't
        // wedge the send path.
        try await controller.send("manual")
        let received = await waitFor("manual\r\n", in: sink)
        #expect(received == Array("manual\r\n".utf8))

        await controller.disconnect()
        await listener.stop()
        drainTask.cancel()
    }
}

private extension [UInt8] {
    /// True if `self` contains `subsequence` as a contiguous run.
    func contains(subsequence: [UInt8]) -> Bool {
        guard !subsequence.isEmpty else { return true }
        return Data(self).range(of: Data(subsequence)) != nil
    }
}

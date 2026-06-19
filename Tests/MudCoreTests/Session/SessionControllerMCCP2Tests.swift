import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — MCCP2", .serialized)
struct SessionControllerMCCP2Tests {
    // MARK: - Helpers

    /// `IAC SB COMPRESS2 IAC SE` — the wire signal that switches the
    /// inbound byte stream to zlib.
    private static let mccp2Start: [UInt8] = [
        TelnetCommand.iac, TelnetCommand.sb, TelnetOption.mccp2,
        TelnetCommand.iac, TelnetCommand.se
    ]

    // MARK: - Negotiation

    @Test("Telnet: WILL MCCP2 from server is ACCEPTED (DO MCCP2 reply)")
    func telnetWillMCCP2IsAccepted() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        let willMCCP2: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.mccp2
        ]
        try await listener.send(willMCCP2)

        let expectedReply: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.do, TelnetOption.mccp2
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

    // MARK: - Inflate path

    @Test("Compressed inbound bytes after IAC SB COMPRESS2 IAC SE inflate to Lines")
    func compressedInboundIsInflated() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        // Build the wire payload:
        //   1. The MCCP2 activation marker (plain).
        //   2. A zlib-compressed line.
        let deflater = try Deflater()
        let compressed = try deflater.compress(
            Array("hello compressed world\n".utf8)
        )
        var wire = Self.mccp2Start
        wire.append(contentsOf: compressed)

        let storeStream = await controller.scrollbackStore.subscribe()
        try await listener.send(wire)

        var firstLine: Line?
        for await line in storeStream {
            firstLine = line
            break
        }
        let captured = try #require(firstLine)
        #expect(captured.text == "hello compressed world")

        let compressionFlag = await controller.isCompressionActive
        #expect(compressionFlag)

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Plain text BEFORE the MCCP2 marker is still processed plainly")
    func plainBeforeMarkerStaysPlain() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        // Wire shape: "Welcome!\n" | IAC SB COMPRESS2 IAC SE | <compressed "After.\n">
        var wire: [UInt8] = Array("Welcome!\n".utf8)
        wire.append(contentsOf: Self.mccp2Start)
        let deflater = try Deflater()
        let compressed = try deflater.compress(Array("After.\n".utf8))
        wire.append(contentsOf: compressed)

        let storeStream = await controller.scrollbackStore.subscribe()
        try await listener.send(wire)

        var lines: [Line] = []
        for await line in storeStream {
            lines.append(line)
            if lines.count == 2 { break }
        }
        #expect(lines.map(\.text) == ["Welcome!", "After."])

        await controller.disconnect()
        await listener.stop()
    }

    @Test("MCCP2 marker + compressed payload split across two chunks")
    func mccp2SplitAcrossChunks() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        let storeStream = await controller.scrollbackStore.subscribe()

        // Chunk 1: activation marker only.
        try await listener.send(Self.mccp2Start)

        // Chunk 2: compressed text. We deflated separately so the test
        // verifies that activation persists across the chunk boundary.
        let deflater = try Deflater()
        let compressed = try deflater.compress(Array("split-chunk line\n".utf8))
        try await listener.send(compressed)

        var firstLine: Line?
        for await line in storeStream {
            firstLine = line
            break
        }
        let captured = try #require(firstLine)
        #expect(captured.text == "split-chunk line")

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Multiple compressed segments accumulate into multiple Lines")
    func multipleCompressedSegmentsBecomeMultipleLines() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        let storeStream = await controller.scrollbackStore.subscribe()

        let deflater = try Deflater()
        let seg1 = try deflater.deflate(
            Array("first line\n".utf8),
            flush: .sync
        )
        let seg2 = try deflater.deflate(
            Array("second line\n".utf8),
            flush: .sync
        )

        var wire = Self.mccp2Start
        wire.append(contentsOf: seg1)
        try await listener.send(wire)
        try await listener.send(seg2)

        var lines: [Line] = []
        for await line in storeStream {
            lines.append(line)
            if lines.count == 2 { break }
        }
        #expect(lines.map(\.text) == ["first line", "second line"])

        await controller.disconnect()
        await listener.stop()
    }

    @Test("Corrupt MCCP input surfaces a note without a clean-session end")
    func corruptMCCPInputSurfacesDiagnostic() async throws {
        let connection = InMemoryConnection()
        let controller = SessionController(makeConnection: { connection })
        let cleanEnd = CleanEndFlag()
        await controller.setCleanSessionEndHandler { cleanEnd.fired = true }

        let storeStream = await controller.scrollbackStore.subscribe()
        try await controller.connect(to: .init(host: "127.0.0.1", port: 1))

        connection.injectInbound(Self.mccp2Start + [0xFF, 0xFE, 0xFD, 0xFC])

        var diagnostic: Line?
        for await line in storeStream {
            guard line.text.contains("[Proteles] Inbound stream error") else { continue }
            diagnostic = line
            break
        }

        let note = try #require(diagnostic)
        #expect(note.text.contains("compressed MCCP data was corrupt"))

        try await Task.sleep(for: .milliseconds(50))
        #expect(!cleanEnd.fired)
        #expect(await controller.state == .disconnected)
    }
}

private final class CleanEndFlag: @unchecked Sendable {
    var fired = false
}

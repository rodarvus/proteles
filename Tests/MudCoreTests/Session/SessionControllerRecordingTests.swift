import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — recording", .serialized)
struct SessionControllerRecordingTests {
    @Test("isRecording is false before startRecording is called")
    func notRecordingByDefault() async {
        let controller = SessionController()
        let recording = await controller.isRecording
        #expect(!recording)
    }

    @Test("startRecording flips isRecording; stopRecording flips it back")
    func startStopTogglesFlag() async throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = SessionController()
        try await controller.startRecording(to: url)
        let after = await controller.isRecording
        #expect(after)

        await controller.stopRecording()
        let afterStop = await controller.isRecording
        #expect(!afterStop)
    }

    @Test("Bytes received over the wire are recorded to disk; replay yields the same bytes")
    func recordWhileReceivingThenReplay() async throws {
        let recordingURL = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }

        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()
        try await controller.startRecording(to: recordingURL)

        let payload = Array("Hello from a recorded session.\n".utf8)
        let storeStream = await controller.scrollbackStore.subscribe()
        try await listener.send(payload)

        // Wait for the line to land in scrollback (proxy for "byte
        // chunk processed", which is what we care about).
        var firstLine: Line?
        for await line in storeStream {
            firstLine = line
            break
        }
        _ = try #require(firstLine)

        await controller.stopRecording()
        await controller.disconnect()
        await listener.stop()

        // Replay file back through a fresh pipeline; same line should
        // emerge.
        let replayer = try SessionReplayer(url: recordingURL)
        #expect(replayer.chunks.count >= 1)
        // Concatenate all recorded bytes — TCP may have split them
        // across multiple receives, which is exactly what we want
        // recording to capture faithfully.
        let recordedBytes = replayer.chunks.flatMap { Array($0.bytes) }
        #expect(recordedBytes == payload)

        var pipeline = LinePipeline()
        let output = try replayer.replay(into: &pipeline)
        #expect(output.lines.map(\.text) == ["Hello from a recorded session."])
    }

    @Test("Calling startRecording while already recording rotates to a fresh file")
    func startRecordingRotatesActiveRecording() async throws {
        let first = temporaryRecordingURL()
        let second = temporaryRecordingURL()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let listener = LoopbackListener()
        let port = try await listener.start()

        let controller = SessionController()
        try await controller.connect(
            to: .init(host: "127.0.0.1", port: port)
        )
        await listener.waitForConnection()

        try await controller.startRecording(to: first)
        let storeStream = await controller.scrollbackStore.subscribe()
        try await listener.send(Array("first line\n".utf8))
        for await _ in storeStream {
            break
        }

        try await controller.startRecording(to: second)
        try await listener.send(Array("second line\n".utf8))
        for await _ in storeStream where await controller.scrollbackStore.count >= 2 {
            break
        }

        await controller.stopRecording()
        await controller.disconnect()
        await listener.stop()

        // First file should have "first line"; second should have
        // "second line".
        let r1 = try SessionReplayer(url: first)
        let r2 = try SessionReplayer(url: second)
        let firstBytes = r1.chunks.flatMap { Array($0.bytes) }
        let secondBytes = r2.chunks.flatMap { Array($0.bytes) }
        #expect(firstBytes == Array("first line\n".utf8))
        #expect(secondBytes == Array("second line\n".utf8))
    }
}

@Suite("SessionRecorder.defaultRecordingURL")
struct SessionRecorderDefaultLocationTests {
    @Test("Produces a session-YYYYMMDD-HHMMSS.jsonl filename in the recordings folder")
    func defaultLocationShape() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try SessionRecorder.defaultRecordingURL(now: fixedDate)
        let filename = url.lastPathComponent
        #expect(filename.hasPrefix("session-"))
        #expect(filename.hasSuffix(".jsonl"))
        // Timestamp portion must be exactly 15 chars (YYYYMMDD-HHMMSS).
        let stamp = filename
            .dropFirst("session-".count)
            .dropLast(".jsonl".count)
        #expect(stamp.count == 15)
        #expect(url.deletingLastPathComponent().lastPathComponent == "recordings")
    }
}

// MARK: - Helpers

private func temporaryRecordingURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "proteles-record-test-\(UUID().uuidString).jsonl"
    )
}

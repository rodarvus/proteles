import Foundation
@testable import MudCore
import Testing

@Suite("SessionRecorder + SessionReplayer — round-trip")
struct SessionRecordReplayRoundTripTests {
    @Test("Record three chunks, replay them, get them back identically")
    func roundTripChunks() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try SessionRecorder(url: url)
        let chunks: [(Date, [UInt8])] = [
            (Date(timeIntervalSince1970: 1_700_000_000), Array("welcome\n".utf8)),
            (Date(timeIntervalSince1970: 1_700_000_000.5), Array("you see\n".utf8)),
            (Date(timeIntervalSince1970: 1_700_000_001), Array("a sign.\n".utf8))
        ]
        for (timestamp, bytes) in chunks {
            try recorder.record(bytes, timestamp: timestamp)
        }
        recorder.close()

        let replayer = try SessionReplayer(url: url)
        #expect(replayer.chunks.count == 3)
        #expect(replayer.chunks.map(\.timestamp) == chunks.map(\.0))
        #expect(replayer.chunks.map { Array($0.bytes) } == chunks.map(\.1))
        #expect(replayer.totalByteCount == chunks.reduce(0) { $0 + $1.1.count })
        #expect(replayer.duration == 1.0)
    }

    @Test("Recording arbitrary binary bytes survives base64 round-trip")
    func arbitraryBytesSurviveBase64() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try SessionRecorder(url: url)
        // Bytes that would be invalid as UTF-8 — exercises the base64
        // encoding path (zlib-compressed MCCP2 data would look like
        // this in practice).
        let weirdBytes: [UInt8] = [0x00, 0xFF, 0x80, 0x7F, 0x1B, 0x5B, 0xC3]
        try recorder.record(weirdBytes)
        recorder.close()

        let replayer = try SessionReplayer(url: url)
        #expect(replayer.chunks.count == 1)
        #expect(Array(replayer.chunks[0].bytes) == weirdBytes)
    }

    @Test("Empty recording loads as an empty chunks array")
    func emptyRecording() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Create an empty file.
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let replayer = try SessionReplayer(url: url)
        #expect(replayer.chunks.isEmpty)
        #expect(replayer.totalByteCount == 0)
        #expect(replayer.duration == 0)
    }
}

@Suite("SessionReplayer + LinePipeline — end-to-end replay")
struct SessionReplayEndToEndTests {
    @Test("Replay of plain text yields the expected lines")
    func replayPlainText() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try SessionRecorder(url: url)
        try recorder.record(Array("first line\n".utf8))
        try recorder.record(Array("second line\n".utf8))
        recorder.close()

        let replayer = try SessionReplayer(url: url)
        var pipeline = LinePipeline()
        let output = try replayer.replay(into: &pipeline)
        #expect(output.lines.map(\.text) == ["first line", "second line"])
        #expect(output.responses.isEmpty)
        #expect(output.compressionActivations == 0)
    }

    @Test("Replay of MCCP2-compressed bytes inflates correctly")
    func replayMCCP2() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Construct a wire chunk that activates MCCP2 then delivers
        // compressed text — the same shape Aardwolf produces in the
        // wild.
        let mccp2Start: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.mccp2,
            TelnetCommand.iac, TelnetCommand.se
        ]
        let deflater = try Deflater()
        let compressed = try deflater.compress(Array("after compression\n".utf8))
        var wire = mccp2Start
        wire.append(contentsOf: compressed)

        let recorder = try SessionRecorder(url: url)
        try recorder.record(wire)
        recorder.close()

        let replayer = try SessionReplayer(url: url)
        var pipeline = LinePipeline()
        let output = try replayer.replay(into: &pipeline)
        #expect(output.lines.map(\.text) == ["after compression"])
        #expect(output.compressionActivations == 1)
    }

    @Test("Replay of WILL MCCP2 negotiation produces a DO COMPRESS2 response")
    func replayNegotiationProducesResponses() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let willMCCP2: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.mccp2
        ]
        let recorder = try SessionRecorder(url: url)
        try recorder.record(willMCCP2)
        recorder.close()

        let replayer = try SessionReplayer(url: url)
        var pipeline = LinePipeline()
        let output = try replayer.replay(into: &pipeline)
        #expect(output.responses == [
            [TelnetCommand.iac, TelnetCommand.do, TelnetOption.mccp2]
        ])
    }
}

@Suite("SessionReplayer — error handling")
struct SessionReplayerErrorTests {
    @Test("Loading a non-existent file throws openFailed")
    func nonexistentFileThrows() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        do {
            _ = try SessionReplayer(url: bogus)
            Issue.record("expected openFailed")
        } catch let error as SessionReplayer.ReplayerError {
            switch error {
            case .openFailed: break
            default: Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Loading a malformed JSONL file throws parseFailed with the line number")
    func malformedJSONLThrows() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "this is not json\n".write(to: url, atomically: true, encoding: .utf8)

        do {
            _ = try SessionReplayer(url: url)
            Issue.record("expected parseFailed")
        } catch let error as SessionReplayer.ReplayerError {
            if case .parseFailed(let line, _) = error {
                #expect(line == 1)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - Helpers

private func temporaryRecordingURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "proteles-replay-test-\(UUID().uuidString).jsonl"
    )
}

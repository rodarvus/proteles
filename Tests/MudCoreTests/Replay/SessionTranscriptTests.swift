import Foundation
@testable import MudCore
import Testing

@Suite("SessionTranscript — human-readable debug log")
struct SessionTranscriptTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).log")
    }

    @Test("writes one timestamped, categorised line per event")
    func writesCategorisedLines() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try SessionTranscript(url: url)
        let at = Date(timeIntervalSince1970: 1_700_000_000.123)
        log.log(.recv, "You are standing in a field.", timestamp: at)
        log.log(.send, "cp info", timestamp: at)
        log.log(.input, "cp", timestamp: at)
        log.log(.note, "[SnD-DBG] do_cp_check clk=1700000000.120", timestamp: at)
        log.log(.gmcp, #"char.status {"state":3}"#, timestamp: at)
        log.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 5)
        // Each line: "<ISO8601 ms> <CATEGORY padded> <text>"
        #expect(lines[0].contains(" RECV  You are standing in a field."))
        #expect(lines[1].contains(" SEND  cp info"))
        #expect(lines[2].contains(" INPUT cp"))
        #expect(lines[3].contains(" NOTE  [SnD-DBG] do_cp_check clk=1700000000.120"))
        #expect(lines[4].contains(##" GMCP  char.status {"state":3}"##))
        // The timestamp is local-time ISO-8601 (with zone offset) — computed the
        // same way here so the assertion holds on any machine's timezone.
        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        expected.timeZone = TimeZone.current
        let expectedPrefix = expected.string(from: Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(lines[0].hasPrefix(expectedPrefix))
    }

    @Test("escapes embedded newlines so each event stays on one line")
    func escapesNewlines() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try SessionTranscript(url: url)
        log.log(.note, "line one\nline two\r\nline three")
        log.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        // Exactly one physical line (one trailing newline only).
        #expect(contents.count(where: { $0 == "\n" }) == 1)
        #expect(contents.contains(#"line one\nline two\r\nline three"#))
    }

    @Test("a closed transcript ignores further writes")
    func closedIsNoOp() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try SessionTranscript(url: url)
        log.log(.recv, "before close")
        log.close()
        log.log(.recv, "after close")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("before close"))
        #expect(!contents.contains("after close"))
    }

    @Test("the transcript path pairs with the binary recording path")
    func pairedURL() {
        let recording = URL(fileURLWithPath: "/tmp/recordings/session-20260525-120000.jsonl")
        let transcript = SessionTranscript.url(pairedWith: recording)
        #expect(transcript.lastPathComponent == "session-20260525-120000.log")
        #expect(transcript.deletingLastPathComponent() == recording.deletingLastPathComponent())
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("Diagnostics — store + MetricKit payload summary (#24)")
struct DiagnosticsStoreTests {
    /// A realistic `MXDiagnosticPayload.jsonRepresentation()` for a crash.
    private static let crashPayload = """
    {
      "timeStampBegin": "2026-06-02 19:00:00 +0000",
      "timeStampEnd": "2026-06-02 19:30:00 +0000",
      "crashDiagnostics": [
        {
          "version": "1.0.0",
          "diagnosticMetaData": {
            "appVersion": "0.4.4",
            "appBuildVersion": "32",
            "osVersion": "macOS 14.0 (23A344)",
            "deviceType": "Mac15,3",
            "exceptionType": 1,
            "signal": 11,
            "terminationReason": "Namespace SIGNAL, Code 0xb"
          },
          "callStackTree": {
            "callStackPerThread": true,
            "callStacks": [
              {
                "threadAttributed": true,
                "callStackRootFrames": [
                  { "binaryName": "Proteles", "address": 1, "subFrames": [
                    { "binaryName": "MudCore", "address": 2, "subFrames": [
                      { "binaryName": "libswiftCore.dylib", "address": 3 }
                    ]}
                  ]}
                ]
              }
            ]
          }
        }
      ]
    }
    """

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("the payload summary parses kind, version, signal, frames, headline")
    func parsesSummary() {
        let summary = DiagnosticSummary.parse(payloadJSON: Data(Self.crashPayload.utf8))
        #expect(summary.counts[.crash] == 1)
        #expect(summary.counts[.hang] == 0)
        #expect(summary.appVersion == "0.4.4")
        #expect(summary.appBuild == "32")
        #expect(summary.signalName == "SIGSEGV")
        #expect(summary.osVersion == "macOS 14.0 (23A344)")
        #expect(summary.topFrames == ["Proteles", "MudCore", "libswiftCore.dylib"])
        #expect(summary.primaryKind == .crash)
        #expect(summary.headline == "Crash · SIGSEGV · v0.4.4 (32)")
    }

    @Test("garbage / non-object JSON yields an empty summary, never a throw")
    func toleratesGarbage() {
        let summary = DiagnosticSummary.parse(payloadJSON: Data("not json".utf8))
        #expect(summary.counts.values.allSatisfy { $0 == 0 })
        #expect(summary.primaryKind == nil)
        #expect(summary.topFrames.isEmpty)
    }

    @Test("save then reports() round-trips, newest first")
    func saveAndList() throws {
        let store = try DiagnosticsStore(directory: tempDir())
        let early = Date(timeIntervalSince1970: 1_780_000_000)
        try store.save(payloadJSON: Data(Self.crashPayload.utf8), capturedAt: early)
        try store.save(payloadJSON: Data(Self.crashPayload.utf8), capturedAt: early.addingTimeInterval(60))
        let reports = store.reports()
        #expect(reports.count == 2)
        #expect(reports[0].capturedAt > reports[1].capturedAt) // newest first
        #expect(reports[0].summary.signalName == "SIGSEGV")
    }

    @Test("save prunes to the cap, keeping the newest")
    func prunesToCap() throws {
        let store = try DiagnosticsStore(directory: tempDir())
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        for index in 0..<5 {
            try store.save(
                payloadJSON: Data(Self.crashPayload.utf8),
                capturedAt: base.addingTimeInterval(Double(index) * 60),
                keepingLast: 3
            )
        }
        let reports = store.reports()
        #expect(reports.count == 3) // capped
        // The three kept are the newest three (base+4m, +3m, +2m).
        #expect(reports.first?.capturedAt == base.addingTimeInterval(240))
    }

    @Test("delete + deleteAll remove reports")
    func deletion() throws {
        let store = try DiagnosticsStore(directory: tempDir())
        try store.save(payloadJSON: Data(Self.crashPayload.utf8))
        #expect(store.reports().count == 1)
        store.deleteAll()
        #expect(store.reports().isEmpty)
    }

    @Test("summaryText is a content-free block with the headline + frames")
    func summaryText() throws {
        let store = try DiagnosticsStore(directory: tempDir())
        try store.save(payloadJSON: Data(Self.crashPayload.utf8))
        let report = try #require(store.reports().first)
        let text = store.summaryText(for: report)
        #expect(text.contains("Crash · SIGSEGV · v0.4.4 (32)"))
        #expect(text.contains("macOS 14.0"))
        #expect(text.contains("Proteles"))
        #expect(text.contains("1 crash"))
    }

    @Test("correlatedRecording picks the session running at crash time")
    func correlatesRecording() throws {
        let diagDir = tempDir()
        let recordingsDir = tempDir()
        let store = try DiagnosticsStore(directory: diagDir)

        // A diagnostic captured at a fixed instant (no payload window → uses
        // capturedAt). Save it so reports() parses it back from the filename.
        let crashTime = Date(timeIntervalSince1970: 1_780_000_000)
        try store.save(payloadJSON: Data("{}".utf8), capturedAt: crashTime)
        let report = try #require(store.reports().first)

        // Recording filenames use the same local stamp the recorder writes.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        func recording(_ offset: TimeInterval) -> String {
            "session-\(formatter.string(from: crashTime.addingTimeInterval(offset))).log"
        }
        let running = recording(-600) // started 10 min before the crash
        for name in [recording(-3600), running, recording(300)] { // older, running, later
            try Data().write(to: recordingsDir.appendingPathComponent(name))
        }

        let matched = store.correlatedRecording(for: report, recordingsDirectory: recordingsDir)
        #expect(matched == running) // latest session at-or-before the crash
    }
}

import Foundation

/// Manual session recording control (start/stop + status). Split out of the
/// core ``SessionController`` file to keep it within the file-length budget; the
/// auto-record path lives in `establish`.
public extension SessionController {
    /// True while a recording is being written. Surfaced for menu state
    /// tracking; the view layer observes ``recordingStarted`` instead of polling.
    var isRecording: Bool {
        recorder != nil
    }

    /// Start recording every inbound wire chunk to `url` (+ the paired debug
    /// transcript); any prior recording is closed first. Captures raw wire bytes
    /// (pre-decompression/telnet-parse), so a replay exercises the full stack
    /// incl. MCCP2. Best-effort: write failures silence recording, not the session.
    func startRecording(to url: URL) throws {
        recorder?.close()
        transcript?.close()
        recorder = try SessionRecorder(url: url)
        openTranscript(pairedWith: url)
    }

    /// Open the human-readable transcript beside a recording and stamp which
    /// build produced it.
    ///
    /// The stamp is **ungated** — one line per session, and without it no
    /// performance comparison across recordings is valid, because Release and
    /// Debug otherwise look identical while differing by 2.30x (see
    /// ``BuildInfo`` and CLAUDE.md's Release-build rule).
    func openTranscript(pairedWith url: URL) {
        transcript = try? SessionTranscript(url: SessionTranscript.url(pairedWith: url))
        logTranscript(.note, "build: \(BuildInfo.current().transcriptLine)")
    }

    /// Stop the current recording. Idempotent.
    func stopRecording() {
        // No "next line" will arrive to close an open burst.
        PerformanceProbe.shared.flushBurst()
        recorder?.close()
        recorder = nil
        transcript?.close()
        transcript = nil
    }
}

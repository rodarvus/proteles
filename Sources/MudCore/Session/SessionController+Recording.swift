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
        transcript = try? SessionTranscript(url: SessionTranscript.url(pairedWith: url))
    }

    /// Stop the current recording. Idempotent.
    func stopRecording() {
        recorder?.close()
        recorder = nil
        transcript?.close()
        transcript = nil
    }
}

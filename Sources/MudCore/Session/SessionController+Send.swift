import Foundation

/// Low-level outbound primitives, split from ``SessionController`` for the file
/// budget: a single line (text + `\r\n`) and raw bytes (verbatim).
public extension SessionController {
    /// Send a single line to the MUD (raw text + `\r\n`), bypassing alias
    /// expansion. Used for internal sends (autologin, applied effects).
    /// `redactInTranscript` hides secrets (the autologin password) from the
    /// debug transcript while still sending them on the wire.
    func sendLine(_ text: String, redactInTranscript: Bool = false) async throws {
        logTranscript(.send, redactInTranscript ? "<redacted>" : text)
        try await sendRaw(Array((text + "\r\n").utf8))
    }

    /// Send raw bytes verbatim (no line terminator added).
    func sendRaw(_ bytes: [UInt8]) async throws {
        guard let connection else { throw SessionError.notConnected }
        lastOutboundActivity = Date()
        // Time the actual socket write. The `.send` transcript line is logged
        // before this await (it records intent); if the write itself stalls,
        // that's an outbound-path delay we otherwise can't see in a recording
        // (which only tees inbound). Surface a slow write so a "command response
        // was late" report can be pinned to our side vs the server/network.
        let writeStart = Date()
        do {
            try await connection.send(bytes)
            let elapsed = Date().timeIntervalSince(writeStart)
            if elapsed > 0.25 {
                logTranscript(.note, "[slow-send] \(bytes.count)B socket write took \(Int(elapsed * 1000))ms")
            }
        } catch let error as NetworkConnection.ConnectionError {
            switch error {
            case .notConnected:
                throw SessionError.notConnected
            default:
                throw SessionError.sendFailed(error.localizedDescription)
            }
        }
    }
}

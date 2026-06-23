import Foundation

/// Low-level outbound primitives, split from ``SessionController`` for the file
/// budget: a single line (text + `\r\n`) and raw bytes (verbatim).
public extension SessionController {
    /// Send a user-typed command (aliases when a script engine is present, else
    /// verbatim; `\r\n` appended). Tracks `quit` so the ensuing server close is
    /// a clean logout, not a dropped link that would autoreconnect.
    func send(_ command: String) async throws {
        // Typed input cuts stale speech (community canon, `tts enter` toggles)
        // - including the bare "press Enter to shut it up" reflex.
        interruptSpeechForTypedCommand()
        // A bare Enter means nothing at the login prompts but restarts
        // Aardwolf's name flow and strands autologin (the 2026-06-11 resume
        // incident: stray empties dead-ended the login). Drop empties while
        // autologin is mid-flight; the MOTD's "Press Return" comes after.
        if autologin != nil, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        expectsCleanClose = Self.isLogoutQuit(command)
        // Don't drop the resume breadcrumb here - Aardwolf can REFUSE a quit
        // (combat, confirmation) and leave you connected. We only treat it as a
        // clean end if the server actually closes soon after (see
        // ``handleByteStreamEnded`` + ``cleanQuitWindow``). Record when the quit
        // was sent; a non-quit command clears it (you're plainly still playing).
        quitSentAt = expectsCleanClose ? .now : nil
        // Echo typed input (dimmed) so it's visible - e.g. while writing a note.
        // Suppressed when the server echoes (passwords) and for the bare
        // prompt-refresh Enter; the transcript tap is gated the same way.
        if !serverEcho, !command.isEmpty {
            await recordDisplayed(Self.inputEchoLine(command), kind: .userInput)
            logTranscript(.input, command)
        }
        try await dispatchCommand(command)
    }

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

import Foundation

/// Owns one MUD session: a ``NetworkConnection`` plus a ``LinePipeline``
/// that turns received bytes into stored ``Line`` records.
///
/// Phase 2 telnet-negotiation policy:
///   - `WILL MCCP2`  → `DO MCCP2`  (accept compression).
///   - `WILL <anything else>` → `DONT <option>`.
///   - `DO  <anything>`        → `WONT <option>`.
///   - `WONT` / `DONT` need no reply.
///
/// All actual byte-parsing logic lives in ``LinePipeline`` — this actor
/// is the I/O wrapper: it owns the connection, drives the pipeline
/// from the byte stream, dispatches outbound bytes for negotiation
/// replies and user commands, and appends the resulting lines to the
/// scrollback store.
///
/// Concurrency model:
///
///   - The controller is an actor.
///   - ``scrollbackStore``, ``connection``, ``connectionStates`` are
///     `nonisolated` so the SwiftUI view layer can read / observe them
///     without `await`.
///   - Inbound bytes are processed inside a single long-lived `Task`
///     that iterates ``NetworkConnection/bytes``. Pipeline state lives
///     on the actor and is therefore only mutated by that task.
///
/// Reconnect: ``connect(to:)`` resets the pipeline, so a `disconnect`
/// followed by a fresh `connect` on the same controller behaves like
/// a clean start.
public actor SessionController {
    public typealias State = NetworkConnection.State

    /// Errors surfaced to callers.
    public enum SessionError: Error, Sendable, Equatable {
        case alreadyConnected
        case notConnected
        case sendFailed(String)
    }

    /// Backing scrollback. Populated by the inbound pipeline; exposed to
    /// the view layer.
    public nonisolated let scrollbackStore: ScrollbackStore

    /// Underlying network wrapper. Exposed so callers can observe
    /// ``NetworkConnection/states`` directly without going through the
    /// actor.
    public nonisolated let connection: NetworkConnection

    private var pipeline = LinePipeline()
    private var processTask: Task<Void, Never>?
    private var recorder: SessionRecorder?

    /// Active autologin instruction for the current connection, plus the
    /// phase tracking how far through the prompt sequence we are. `nil`
    /// when autologin is not configured or has completed.
    private var autologin: AutologinState?

    private struct AutologinState {
        var plan: AutologinPlan
        var phase: Phase

        enum Phase {
            case awaitingUsername
            case awaitingPassword
            case done
        }
    }

    /// When true, ``connect(to:)`` opens a fresh recording at
    /// ``autoRecordingURL`` so the capture includes every byte from
    /// the first one — crucial for replayable recordings, because
    /// Aardwolf completes the MCCP2 handshake within milliseconds of
    /// TCP-up. The flag is mutable at runtime so a Debug menu can
    /// expose it in a later iteration.
    public var autoRecord: Bool

    /// Where ``autoRecord`` writes. Defaults to
    /// ``SessionRecorder/defaultRecordingURL(now:fileManager:)`` (which
    /// places files under
    /// `~/Library/Application Support/com.proteles.ProtelesApp/recordings/`).
    /// Tests inject a temp-dir builder so they don't litter the
    /// developer's real recordings directory.
    public let autoRecordingURL: @Sendable () -> URL?

    public init(
        scrollbackStore: ScrollbackStore = ScrollbackStore(),
        autoRecord: Bool = false,
        autoRecordingURL: @escaping @Sendable () -> URL? = {
            try? SessionRecorder.defaultRecordingURL()
        }
    ) {
        self.scrollbackStore = scrollbackStore
        connection = NetworkConnection()
        self.autoRecord = autoRecord
        self.autoRecordingURL = autoRecordingURL
    }

    /// Connection-state stream. Forwards from the underlying
    /// ``NetworkConnection``.
    public nonisolated var connectionStates: AsyncStream<State> {
        connection.states
    }

    /// True if MCCP2 has been negotiated and the inbound byte stream is
    /// currently being decompressed.
    public var isCompressionActive: Bool {
        pipeline.isCompressionActive
    }

    /// True while a recording is being written. Surfaced for menu
    /// state tracking; the view layer observes this via
    /// ``recordingStarted`` notifications instead of polling.
    public var isRecording: Bool {
        recorder != nil
    }

    /// Start recording every inbound wire chunk to `url`. Any prior
    /// recording is closed cleanly first. Recordings capture the raw
    /// wire bytes (pre-decompression, pre-telnet-parse), so a replay
    /// exercises the full protocol stack — including MCCP2.
    ///
    /// The recorder is **best-effort** — write failures silence
    /// further recording rather than tear the session down, matching
    /// the rest of MudCore's bias toward keeping the user's session
    /// alive in the face of secondary failures.
    public func startRecording(to url: URL) throws {
        recorder?.close()
        recorder = try SessionRecorder(url: url)
    }

    /// Stop the current recording. Idempotent.
    public func stopRecording() {
        recorder?.close()
        recorder = nil
    }

    /// Open a connection and start the inbound processing pipeline.
    /// If ``autoRecord`` is true and no manual recording is already in
    /// progress, opens a fresh recording at ``autoRecordingURL`` so
    /// the capture starts from byte one (covers the telnet + MCCP2
    /// handshake, which is what makes the recording replayable).
    public func connect(
        to endpoint: NetworkConnection.Endpoint,
        autologin plan: AutologinPlan? = nil
    ) async throws {
        let currentState = await connection.state
        guard currentState == .disconnected else {
            throw SessionError.alreadyConnected
        }
        pipeline.reset()
        autologin = plan.map { AutologinState(plan: $0, phase: .awaitingUsername) }
        try await connection.connect(to: endpoint)

        if autoRecord, recorder == nil, let url = autoRecordingURL() {
            recorder = try? SessionRecorder(url: url)
        }

        startProcessingLoop()
    }

    /// Close the connection. Idempotent.
    public func disconnect() async {
        processTask?.cancel()
        processTask = nil
        recorder?.close()
        recorder = nil
        autologin = nil
        await connection.disconnect()
    }

    /// Send a user-typed command. Appends `\r\n` (the MUD line
    /// terminator). Throws if not connected.
    public func send(_ command: String) async throws {
        let payload = command + "\r\n"
        try await sendRaw(Array(payload.utf8))
    }

    /// Send raw bytes verbatim (no line terminator added).
    public func sendRaw(_ bytes: [UInt8]) async throws {
        do {
            try await connection.send(bytes)
        } catch let error as NetworkConnection.ConnectionError {
            switch error {
            case .notConnected:
                throw SessionError.notConnected
            default:
                throw SessionError.sendFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Private

    private func startProcessingLoop() {
        processTask?.cancel()
        let bytesStream = connection.bytes
        processTask = Task { [weak self] in
            for await chunk in bytesStream {
                await self?.processChunk(chunk)
            }
            await self?.flushOnDisconnect()
        }
    }

    private func processChunk(_ wireBytes: [UInt8]) async {
        // Tee to the recorder before doing any parser work — we want
        // the *wire* bytes on disk so a replay re-runs the full
        // protocol stack (MCCP2 included) deterministically.
        try? recorder?.record(wireBytes)

        let output: LinePipeline.Output
        do {
            output = try pipeline.consume(wireBytes)
        } catch {
            // Corrupt MCCP stream — drop the session. Future phases
            // will surface a user-visible error rather than bail
            // silently.
            await connection.disconnect()
            return
        }

        // Negotiation replies go out before line appends so the server
        // sees them promptly.
        for response in output.responses {
            try? await connection.send(response)
        }
        for line in output.lines {
            await scrollbackStore.append(line)
        }

        await advanceAutologin(newLines: output.lines)
    }

    /// Drive the prompt-driven (Diku-style) autologin sequence. Called
    /// after each processed chunk with the lines it produced.
    ///
    /// Prompts arrive without a trailing newline, so they sit in
    /// ``LinePipeline/pendingLineText`` rather than appearing as a
    /// ``Line``. We scan both the freshly emitted lines (in case a world
    /// terminates its prompts) and the pending buffer.
    private func advanceAutologin(newLines: [Line]) async {
        guard var state = autologin else { return }

        switch state.phase {
        case .awaitingUsername:
            guard sees(state.plan.usernamePrompt, in: newLines) else { return }
            try? await send(state.plan.username)
            // Skip the password wait entirely when there's nothing to
            // send; some characters have no password.
            state.phase = state.plan.password.isEmpty ? .done : .awaitingPassword
        case .awaitingPassword:
            guard sees(state.plan.passwordPrompt, in: newLines) else { return }
            try? await send(state.plan.password)
            state.phase = .done
        case .done:
            break
        }

        autologin = state.phase == .done ? nil : state
    }

    /// True if `needle` appears in any of `lines` or in the pipeline's
    /// current un-terminated pending text.
    private func sees(_ needle: String, in lines: [Line]) -> Bool {
        guard !needle.isEmpty else { return false }
        if pipeline.pendingLineText.contains(needle) { return true }
        return lines.contains { $0.text.contains(needle) }
    }

    private func flushOnDisconnect() async {
        let trailing = pipeline.flush()
        for line in trailing {
            await scrollbackStore.append(line)
        }
    }
}

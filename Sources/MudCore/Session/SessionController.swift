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

    public init(scrollbackStore: ScrollbackStore = ScrollbackStore()) {
        self.scrollbackStore = scrollbackStore
        connection = NetworkConnection()
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
    public func connect(to endpoint: NetworkConnection.Endpoint) async throws {
        let currentState = await connection.state
        guard currentState == .disconnected else {
            throw SessionError.alreadyConnected
        }
        pipeline.reset()
        try await connection.connect(to: endpoint)
        startProcessingLoop()
    }

    /// Close the connection. Idempotent.
    public func disconnect() async {
        processTask?.cancel()
        processTask = nil
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
    }

    private func flushOnDisconnect() async {
        let trailing = pipeline.flush()
        for line in trailing {
            await scrollbackStore.append(line)
        }
    }
}

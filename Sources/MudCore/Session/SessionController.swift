import Foundation

/// Owns one MUD session: a ``NetworkConnection`` plus the
/// `bytes → TelnetProcessor → ANSIParser → LineBuilder → ScrollbackStore`
/// pipeline that turns received bytes into stored ``Line`` records.
///
/// Phase 2 telnet-negotiation policy:
///   - `WILL MCCP2`  → `DO MCCP2`  (accept compression).
///   - `WILL <anything else>` → `DONT <option>`.
///   - `DO  <anything>`        → `WONT <option>`.
///   - `WONT` / `DONT` need no reply.
///
/// MCCP2 (PLAN.md §5.3, §8.3): after the server emits
/// `IAC SB COMPRESS2 IAC SE`, every subsequent inbound byte on the wire
/// is zlib-compressed. The controller pipes wire bytes through an
/// ``Inflater`` and feeds the inflated output through TelnetProcessor,
/// ANSIParser, and LineBuilder as usual. Activation in the middle of a
/// chunk is handled correctly: bytes before `IAC SE` are processed plain;
/// bytes after are inflated and re-entered into the pipeline.
///
/// Concurrency model:
///
///   - The controller is an actor.
///   - ``scrollbackStore``, ``connection``, ``connectionStates``, and
///     ``state`` are `nonisolated` so the SwiftUI view layer can read /
///     observe them without `await`.
///   - Inbound bytes are processed inside a single long-lived `Task`
///     that iterates ``NetworkConnection/bytes``. Parser state and the
///     inflater live on the actor and are therefore only mutated by
///     that task.
///
/// Reconnect: ``connect(to:)`` resets the parsers and the inflater, so
/// a `disconnect` followed by a fresh `connect` on the same controller
/// behaves like a clean start.
public actor SessionController {
    /// External, app-level state. Mirrors ``NetworkConnection/State``
    /// today; a later phase will add session-specific phases (e.g.
    /// authenticating, idle, paged) on top.
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

    private var telnet = TelnetProcessor()
    private var ansi = ANSIParser()
    private var lineBuilder = LineBuilder()
    private var inflater: Inflater?
    private var processTask: Task<Void, Never>?

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
    /// currently being decompressed. Exposed for diagnostics; the view
    /// layer doesn't need it for any wiring.
    public var isCompressionActive: Bool {
        inflater != nil
    }

    /// Open a connection and start the inbound processing pipeline.
    /// Idempotent within an actor turn but rejects concurrent open
    /// attempts.
    public func connect(to endpoint: NetworkConnection.Endpoint) async throws {
        let currentState = await connection.state
        guard currentState == .disconnected else {
            throw SessionError.alreadyConnected
        }
        resetParsers()
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

    /// Send raw bytes verbatim (no line terminator added). Used
    /// internally for telnet negotiation responses, but also useful for
    /// tests and any caller that needs precise wire control.
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

    private func resetParsers() {
        telnet.reset()
        ansi.reset()
        lineBuilder.reset()
        inflater = nil
    }

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
        var newLines: [Line] = []
        var negotiationResponses: [[UInt8]] = []

        // If compression is already active, inflate the whole chunk
        // up-front. Any in-chunk MCCP2 *activation* would only happen
        // when compression was NOT yet active; once active, the entire
        // wire stream is compressed.
        var buffer: [UInt8]
        if let inflater {
            do {
                buffer = try inflater.inflate(wireBytes)
            } catch {
                // Corrupt MCCP stream — best response is to drop the
                // session. Future phases may attempt a clean disconnect
                // with a user-visible error; Phase 2 just bails.
                await connection.disconnect()
                return
            }
        } else {
            buffer = wireBytes
        }

        var index = 0
        while index < buffer.count {
            var activatedCompression = false
            let consumed = telnet.processInterruptible(buffer[index...]) { event in
                self.handleEvent(
                    event,
                    lines: &newLines,
                    responses: &negotiationResponses,
                    activatedCompression: &activatedCompression
                )
                // If MCCP2 just turned on, halt now so we can inflate
                // the rest of the buffer before continuing.
                return !activatedCompression
            }
            index += consumed

            if activatedCompression {
                inflater = try? Inflater()
                guard let inflater else {
                    // Inflater init failed — disconnect.
                    await connection.disconnect()
                    return
                }
                if index < buffer.count {
                    let compressedRemainder = Array(buffer[index...])
                    do {
                        buffer = try inflater.inflate(compressedRemainder)
                    } catch {
                        await connection.disconnect()
                        return
                    }
                    index = 0
                }
            }
        }

        // Negotiation responses go out before line appends so the server
        // sees them promptly.
        for response in negotiationResponses {
            try? await connection.send(response)
        }
        for line in newLines {
            await scrollbackStore.append(line)
        }
    }

    private func handleEvent(
        _ event: TelnetEvent,
        lines: inout [Line],
        responses: inout [[UInt8]],
        activatedCompression: inout Bool
    ) {
        switch event {
        case .data(let byte):
            feedANSI(byte: byte, lines: &lines)
        case .negotiate(let verb, let option):
            if let response = negotiationResponse(verb: verb, option: option) {
                responses.append(response)
            }
        case .subnegotiation(let option, _) where option == TelnetOption.mccp2:
            activatedCompression = true
        case .command, .subnegotiation:
            // Other standalone commands and subnegotiations (GMCP,
            // MSDP, …) are ignored in Phase 2. They land in Phase 4.
            break
        }
    }

    private func feedANSI(byte: UInt8, lines: inout [Line]) {
        ansi.process([byte]) { ansiEvent in
            self.lineBuilder.consume(ansiEvent) { line in
                lines.append(line)
            }
        }
    }

    /// Phase-2 policy: accept MCCP2 (WILL → DO), refuse everything else.
    /// WONT and DONT are confirmations from the server and need no
    /// reply.
    private func negotiationResponse(
        verb: TelnetVerb,
        option: UInt8
    ) -> [UInt8]? {
        let responseVerb: UInt8
        switch verb {
        case .will:
            responseVerb = option == TelnetOption.mccp2
                ? TelnetCommand.do
                : TelnetCommand.dont
        case .do:
            responseVerb = TelnetCommand.wont
        case .wont, .dont:
            return nil
        }
        return [TelnetCommand.iac, responseVerb, option]
    }

    private func flushOnDisconnect() async {
        var trailingLines: [Line] = []
        ansi.flush { ansiEvent in
            self.lineBuilder.consume(ansiEvent) { line in
                trailingLines.append(line)
            }
        }
        lineBuilder.flush { line in
            trailingLines.append(line)
        }
        for line in trailingLines {
            await scrollbackStore.append(line)
        }
    }
}

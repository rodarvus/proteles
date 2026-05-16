import Foundation

/// Owns one MUD session: a ``NetworkConnection`` plus the
/// `bytes → TelnetProcessor → ANSIParser → LineBuilder → ScrollbackStore`
/// pipeline that turns received bytes into stored ``Line`` records.
///
/// Phase 1 telnet-negotiation policy is **refuse everything**: we reply
/// `DONT` to every `WILL` and `WONT` to every `DO`. This is sufficient
/// for "connect to Aardwolf and watch text scroll" — option-specific
/// handling (TTYPE/MTTS, MCCP2 decompression, GMCP) lands in later
/// phases (PLAN.md §5.2, §8.3, §8.5).
///
/// Concurrency model:
///
///   - The controller is an actor.
///   - ``scrollbackStore``, ``connection``, ``connectionStates``, and
///     ``state`` are `nonisolated` so the SwiftUI view layer can read /
///     observe them without `await`.
///   - Inbound bytes are processed inside a single long-lived `Task`
///     that iterates ``NetworkConnection/bytes``. Parser state lives
///     on the actor and is therefore only mutated by that task.
///
/// Reconnect: ``connect(to:)`` resets the parsers and rebinds the
/// processing task, so a `disconnect` followed by a fresh `connect` on
/// the same controller behaves like a clean start.
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

    private func processChunk(_ bytes: [UInt8]) async {
        var newLines: [Line] = []
        var negotiationResponses: [[UInt8]] = []

        telnet.process(bytes) { event in
            switch event {
            case .data(let byte):
                self.feedANSI(byte: byte, lines: &newLines)
            case .negotiate(let verb, let option):
                if let response = self.negotiationResponse(verb: verb, option: option) {
                    negotiationResponses.append(response)
                }
            case .command, .subnegotiation:
                // Phase 1: ignore standalone commands (NOP, GA, AYT, …)
                // and all subnegotiation payloads (GMCP, MCCP2, …). Real
                // handling arrives in later phases (PLAN.md §5).
                break
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

    private func feedANSI(byte: UInt8, lines: inout [Line]) {
        ansi.process([byte]) { ansiEvent in
            self.lineBuilder.consume(ansiEvent) { line in
                lines.append(line)
            }
        }
    }

    /// Phase-1 policy: refuse every option. WILL → DONT, DO → WONT.
    /// WONT and DONT are confirmations from the server and need no
    /// reply.
    private func negotiationResponse(
        verb: TelnetVerb,
        option: UInt8
    ) -> [UInt8]? {
        let responseVerb: UInt8
        switch verb {
        case .will: responseVerb = TelnetCommand.dont
        case .do: responseVerb = TelnetCommand.wont
        case .wont, .dont: return nil
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

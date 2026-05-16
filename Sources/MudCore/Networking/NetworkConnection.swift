import Foundation
import Network

/// Async wrapper around `NWConnection` for a single MUD session.
///
/// Owns the connection lifecycle and exposes:
///
///   - ``bytes``  inbound byte chunks as an `AsyncStream<[UInt8]>`
///   - ``states`` connection state transitions as an `AsyncStream<State>`
///   - ``connect(to:)``, ``send(_:)``, ``disconnect()``  the control surface
///
/// State machine:
///
///     disconnected --connect()--> connecting --(NW ready)--> connected
///                                       |                       |
///                                       +-(NW failed/cancelled)-+
///                                                |              |
///                                                v              v
///                                          disconnected <-- closing
///
/// A failed connect call resets the actor to `.disconnected`, so callers
/// can retry without recreating the wrapper.
///
/// Notes:
///   - The streams are created once at init and live for the actor's
///     lifetime. They are designed for a single consumer each
///     (the session controller).
///   - This is a one-shot wrapper. ``disconnect()`` plus a fresh
///     ``connect(to:)`` works for a reconnect, but the actor is not
///     designed for parallel connections.
public actor NetworkConnection {
    /// Where to connect.
    public struct Endpoint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let useTLS: Bool

        public init(host: String, port: UInt16, useTLS: Bool = false) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
        }
    }

    /// External, Proteles-level state. Maps from `NWConnection.State`
    /// onto a smaller, MUD-focused set.
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case closing
    }

    /// Errors surfaced to callers.
    public enum ConnectionError: Error, Sendable, Equatable {
        case invalidPort(UInt16)
        case alreadyActive
        case notConnected
        case connectionFailed(String)
        case sendFailed(String)
        case cancelled
    }

    /// Async stream of inbound byte chunks. Each yielded element is one
    /// chunk delivered by `NWConnection`; chunking is not aligned with
    /// any protocol boundary, so consumers must tolerate arbitrary
    /// splits (which the Telnet/ANSI parsers do).
    public nonisolated let bytes: AsyncStream<[UInt8]>

    /// Async stream of state transitions, fired on every change.
    public nonisolated let states: AsyncStream<State>

    public private(set) var state: State = .disconnected

    private let bytesContinuation: AsyncStream<[UInt8]>.Continuation
    private let stateContinuation: AsyncStream<State>.Continuation
    private let queue = DispatchQueue(
        label: "com.proteles.NetworkConnection",
        qos: .userInitiated
    )

    private var connection: NWConnection?
    private var pendingConnect: CheckedContinuation<Void, Error>?

    public init() {
        let (bytesStream, bytesCont) = AsyncStream<[UInt8]>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (stateStream, stateCont) = AsyncStream<State>.makeStream(
            bufferingPolicy: .unbounded
        )
        bytes = bytesStream
        bytesContinuation = bytesCont
        states = stateStream
        stateContinuation = stateCont
    }

    deinit {
        bytesContinuation.finish()
        stateContinuation.finish()
    }

    /// Open a TCP (or TLS) connection. Throws on invalid endpoint or
    /// failure to establish the connection. The wrapper must be
    /// ``State/disconnected`` on entry.
    public func connect(to endpoint: Endpoint) async throws {
        guard state == .disconnected else {
            throw ConnectionError.alreadyActive
        }
        // NWEndpoint.Port accepts rawValue 0 silently, but a port of 0
        // makes NWConnection wait indefinitely for an OS-assigned port
        // that never arrives in client mode. Reject explicitly.
        guard endpoint.port != 0,
              let port = NWEndpoint.Port(rawValue: endpoint.port)
        else {
            throw ConnectionError.invalidPort(endpoint.port)
        }

        let nwEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(endpoint.host),
            port: port
        )
        let parameters: NWParameters = endpoint.useTLS ? .tls : .tcp
        let conn = NWConnection(to: nwEndpoint, using: parameters)
        connection = conn

        transition(to: .connecting)

        do {
            try await withCheckedThrowingContinuation { cont in
                pendingConnect = cont
                conn.stateUpdateHandler = { [weak self] newState in
                    Task { [weak self] in
                        await self?.handleNWStateUpdate(newState)
                    }
                }
                conn.start(queue: queue)
            }
        } catch {
            // Failure already cleaned up in handleNWStateUpdate, but
            // ensure state reflects disconnected.
            transition(to: .disconnected)
            connection = nil
            throw error
        }

        startReceiveLoop(on: conn)
    }

    /// Send raw bytes. Throws if not connected.
    public func send(_ data: Data) async throws {
        guard state == .connected, let conn = connection else {
            throw ConnectionError.notConnected
        }
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Error>) in
            conn.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(
                            throwing: ConnectionError.sendFailed(
                                error.localizedDescription
                            )
                        )
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    /// Send raw bytes (`[UInt8]` convenience). Throws if not connected.
    public func send(_ rawBytes: [UInt8]) async throws {
        try await send(Data(rawBytes))
    }

    /// Close the connection. Idempotent — calling on an already-disconnected
    /// wrapper is a no-op.
    public func disconnect() async {
        guard let conn = connection, state != .disconnected else { return }
        transition(to: .closing)
        conn.cancel()
        // The `.cancelled` `NWConnection.State` transition finalises
        // bytes stream and resets `state` to `.disconnected`.
    }

    // MARK: - Private

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        stateContinuation.yield(newState)
    }

    private func handleNWStateUpdate(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            handleReady()
        case .failed(let error):
            handleFailed(error)
        case .cancelled:
            handleCancelled()
        case .waiting, .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    private func handleReady() {
        transition(to: .connected)
        if let cont = pendingConnect {
            pendingConnect = nil
            cont.resume()
        }
    }

    private func handleFailed(_ error: NWError) {
        let description = error.localizedDescription
        if let cont = pendingConnect {
            pendingConnect = nil
            cont.resume(throwing: ConnectionError.connectionFailed(description))
        } else {
            // Failure after connection was established.
            bytesContinuation.finish()
        }
        transition(to: .disconnected)
        connection?.cancel()
        connection = nil
    }

    private func handleCancelled() {
        if let cont = pendingConnect {
            pendingConnect = nil
            cont.resume(throwing: ConnectionError.cancelled)
        } else {
            bytesContinuation.finish()
        }
        transition(to: .disconnected)
        connection = nil
    }

    private func startReceiveLoop(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, isComplete, error in
            Task { [weak self] in
                await self?.handleReceived(
                    data: data,
                    isComplete: isComplete,
                    error: error
                )
            }
        }
    }

    private func handleReceived(
        data: Data?,
        isComplete: Bool,
        error: NWError?
    ) {
        if let data, !data.isEmpty {
            bytesContinuation.yield(Array(data))
        }
        if error != nil {
            bytesContinuation.finish()
            connection?.cancel()
            return
        }
        if isComplete {
            bytesContinuation.finish()
            transition(to: .disconnected)
            connection?.cancel()
            connection = nil
            return
        }
        if let conn = connection {
            startReceiveLoop(on: conn)
        }
    }
}

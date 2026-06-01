import Foundation

/// The slice of ``NetworkConnection`` that ``SessionController`` drives,
/// abstracted behind a protocol so tests can substitute an in-memory
/// connection — one that captures outbound sends and lets the test inject
/// inbound bytes — and exercise the *real* session pipeline + timer loop
/// without a socket. Production always uses ``NetworkConnection``.
///
/// `bytes`/`states` are `nonisolated` so the session can read the streams
/// synchronously (as it does today); the I/O methods stay `async`.
public protocol MudConnection: Sendable {
    /// Inbound raw wire byte chunks as they arrive.
    nonisolated var bytes: AsyncStream<[UInt8]> { get }
    /// Connection-state transitions.
    nonisolated var states: AsyncStream<NetworkConnection.State> { get }
    func connect(to endpoint: NetworkConnection.Endpoint, timeout: Duration) async throws
    func send(_ data: Data) async throws
    func send(_ rawBytes: [UInt8]) async throws
    func disconnect() async
}

public extension MudConnection {
    /// Connect with the default timeout (matches ``NetworkConnection``'s default).
    func connect(to endpoint: NetworkConnection.Endpoint) async throws {
        try await connect(to: endpoint, timeout: NetworkConnection.defaultConnectTimeout)
    }
}

extension NetworkConnection: MudConnection {}

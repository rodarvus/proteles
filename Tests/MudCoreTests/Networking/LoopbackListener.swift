import Foundation
import Network

/// Minimal in-process TCP listener used by ``NetworkConnection``
/// integration tests. Binds to `127.0.0.1` on an OS-assigned free port,
/// accepts a single inbound connection, and exposes two affordances:
///
///   - ``send(_:)`` — push bytes back to the client.
///   - ``received`` — `AsyncStream<[UInt8]>` of bytes received from the
///     client.
///
/// This is *not* a generic mock MUD server (that arrives later, alongside
/// scripted scenarios). It is intentionally tiny: just enough to verify
/// connect / send / receive / disconnect against a real Network.framework
/// peer.
actor LoopbackListener {
    enum ListenerError: Error {
        case startFailed(String)
        case sendFailed(String)
        case notReady
    }

    nonisolated let received: AsyncStream<[UInt8]>
    private let receivedContinuation: AsyncStream<[UInt8]>.Continuation
    private let queue = DispatchQueue(
        label: "com.proteles.LoopbackListener"
    )

    private var listener: NWListener?
    private var connection: NWConnection?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var connectionReadyContinuations: [CheckedContinuation<Void, Never>] = []
    private var isConnectionReady = false
    private(set) var port: UInt16 = 0

    init() {
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream(
            bufferingPolicy: .unbounded
        )
        received = stream
        receivedContinuation = continuation
    }

    deinit {
        receivedContinuation.finish()
    }

    /// Start listening on a free localhost port. Returns the assigned port.
    func start() async throws -> UInt16 {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            throw ListenerError.startFailed(error.localizedDescription)
        }
        self.listener = listener

        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Error>) in
            startContinuation = cont
            listener.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in
                    await self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: queue)
        }

        return port
    }

    /// Push bytes back to the connected client.
    func send(_ bytes: [UInt8]) async throws {
        guard let connection else { throw ListenerError.notReady }
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(
                            throwing: ListenerError.sendFailed(
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

    /// Wait until the listener has accepted an inbound connection and
    /// that connection is `.ready`. Returns immediately if already ready.
    /// Required for tests that push bytes *from* the listener
    /// immediately after the client's `connect(to:)` returns — the
    /// listener's accept callback runs asynchronously on its own queue
    /// and may not have finished by then.
    func waitForConnection() async {
        if isConnectionReady { return }
        await withCheckedContinuation { cont in
            connectionReadyContinuations.append(cont)
        }
    }

    /// Shut down. Cancels the active connection (if any) and the
    /// listener; idempotent.
    func stop() async {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        receivedContinuation.finish()
    }

    // MARK: - Private

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let raw = listener?.port?.rawValue {
                port = raw
            }
            if let cont = startContinuation {
                startContinuation = nil
                cont.resume()
            }
        case .failed(let error):
            if let cont = startContinuation {
                startContinuation = nil
                cont.resume(
                    throwing: ListenerError.startFailed(
                        error.localizedDescription
                    )
                )
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleConnectionState(state)
            }
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isConnectionReady = true
            let waiters = connectionReadyContinuations
            connectionReadyContinuations.removeAll()
            for cont in waiters {
                cont.resume()
            }
            startReceiveLoop()
        case .failed, .cancelled:
            receivedContinuation.finish()
        default:
            break
        }
    }

    private func startReceiveLoop() {
        guard let connection else { return }
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
            receivedContinuation.yield(Array(data))
        }
        if error != nil || isComplete {
            receivedContinuation.finish()
            return
        }
        startReceiveLoop()
    }
}

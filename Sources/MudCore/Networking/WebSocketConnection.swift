import Foundation

/// A ``MudConnection`` over Aardwolf's WebSocket gateway
/// (`wss://play.aardwolf.com:6200/`) using `URLSessionWebSocketTask` — the
/// transport for iOS (where raw TCP is awkward) and a selectable alternative on
/// macOS. Everything above the byte boundary (telnet, ANSI, GMCP, scripting,
/// mapper, S&D) is unchanged: this class just translates between the gateway's
/// framing and the raw telnet stream the pipeline expects (see ``WebSocketFraming``).
///
/// Lifecycle: ``connect(to:timeout:)`` opens the socket, sends the JSON handshake
/// (telling the gateway which MUD host/port to bridge to), and resolves once the
/// bridge is up — signalled by the **first inbound frame**. Outbound is gated
/// until then (sending before the bridge is ready makes the gateway drop the
/// connection — verified live), so anything sent early is queued and flushed.
///
/// One-shot, like ``NetworkConnection``: a fresh instance per connection (the
/// streams finish on disconnect).
public final class WebSocketConnection: NSObject, MudConnection, @unchecked Sendable {
    public nonisolated let bytes: AsyncStream<[UInt8]>
    public nonisolated let states: AsyncStream<NetworkConnection.State>
    private let bytesContinuation: AsyncStream<[UInt8]>.Continuation
    private let stateContinuation: AsyncStream<NetworkConnection.State>.Continuation

    private let gatewayURL: URL
    private let ttype: String
    private let client: String

    /// Guards the mutable state below. Only ever held across **synchronous**
    /// work (via `withLock`), never an `await`.
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var inflater: Inflater?
    private var bridgeReady = false
    private var queued: [WebSocketFraming.Outbound] = []
    private var state: NetworkConnection.State = .disconnected
    private var pendingConnect: CheckedContinuation<Void, Error>?

    public init(
        gatewayURL: URL = URL(string: "wss://play.aardwolf.com:6200/")!,
        ttype: String = "Proteles",
        client: String = "Proteles"
    ) {
        self.gatewayURL = gatewayURL
        self.ttype = ttype
        self.client = client
        (bytes, bytesContinuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        (states, stateContinuation) = AsyncStream<NetworkConnection.State>
            .makeStream(bufferingPolicy: .unbounded)
        super.init()
    }

    // MARK: - Connect

    public func connect(to endpoint: NetworkConnection.Endpoint, timeout: Duration) async throws {
        let task: URLSessionWebSocketTask? = lock.withLock {
            guard state == .disconnected else { return nil }
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: gatewayURL)
            self.session = session
            self.task = task
            inflater = try? Inflater(raw: true)
            return task
        }
        guard let task else { throw NetworkConnection.ConnectionError.alreadyActive }

        transition(to: .connecting)
        task.resume()
        // Handshake first (creates the telnet bridge), then start receiving.
        let handshake = WebSocketFraming.handshakeJSON(
            host: endpoint.host, port: endpoint.port, ttype: ttype, client: client
        )
        try? await task.send(.string(handshake))
        startReceiveLoop(task: task)

        // Resolve once the bridge is up (first inbound frame) or time out.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.failConnect(.timedOut)
        }
        defer { timeoutTask.cancel() }
        do {
            try await withCheckedThrowingContinuation { cont in
                lock.withLock { pendingConnect = cont }
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    // MARK: - Receive

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    if case .string(let frame) = message { handleInbound(frame) }
                    // The gateway never sends binary frames; ignore if it does.
                } catch {
                    guard let self else { return }
                    failConnect(.connectionFailed(error.localizedDescription))
                    transition(to: .disconnected)
                    finish()
                    return
                }
            }
        }
    }

    /// What `handleInbound` decided to do outside the lock.
    private struct InboundStep {
        var bytes: [UInt8]
        var firstFrame: Bool
        var flush: [WebSocketFraming.Outbound]
        var connectContinuation: CheckedContinuation<Void, Error>?
    }

    private func handleInbound(_ frame: String) {
        let step: InboundStep? = lock.withLock {
            guard let inflater else { return nil }
            let out = WebSocketFraming.inboundBytes(fromBase64: frame, inflater: inflater)
            if bridgeReady { return InboundStep(bytes: out, firstFrame: false, flush: []) }
            bridgeReady = true
            let flush = queued
            queued = []
            let cont = pendingConnect
            pendingConnect = nil
            return InboundStep(bytes: out, firstFrame: true, flush: flush, connectContinuation: cont)
        }
        guard let step else { return }
        if step.firstFrame {
            transition(to: .connected)
            step.connectContinuation?.resume()
            for frame in step.flush {
                Task { await self.transmit(frame) }
            }
        }
        if !step.bytes.isEmpty { bytesContinuation.yield(step.bytes) }
    }

    // MARK: - Send

    public func send(_ data: Data) async throws {
        try await send([UInt8](data))
    }

    public func send(_ rawBytes: [UInt8]) async throws {
        for frame in WebSocketFraming.outboundFrames(from: rawBytes) {
            let ready = lock.withLock { () -> Bool in
                if bridgeReady { return true }
                queued.append(frame)
                return false
            }
            if ready { await transmit(frame) }
        }
    }

    private func transmit(_ frame: WebSocketFraming.Outbound) async {
        guard let task = lock.withLock({ self.task }) else { return }
        let message: String = switch frame {
        case .text(let string): string
        case .gmcp(let payload): WebSocketFraming.gmcpJSON(payload)
        }
        try? await task.send(.string(message))
    }

    // MARK: - Teardown

    public func disconnect() async {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            let task = self.task
            self.task = nil
            self.session = nil
            self.inflater = nil
            return task
        }
        task?.cancel(with: .goingAway, reason: nil)
        transition(to: .disconnected)
        finish()
    }

    // MARK: - Helpers

    private func failConnect(_ error: NetworkConnection.ConnectionError) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let cont = pendingConnect
            pendingConnect = nil
            return cont
        }
        cont?.resume(throwing: error)
    }

    private func transition(to newState: NetworkConnection.State) {
        let changed = lock.withLock { () -> Bool in
            guard state != newState else { return false }
            state = newState
            return true
        }
        if changed { stateContinuation.yield(newState) }
    }

    private func finish() {
        bytesContinuation.finish()
        stateContinuation.finish()
    }
}

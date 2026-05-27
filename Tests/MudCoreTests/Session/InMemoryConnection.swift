import Foundation
@testable import MudCore

/// An in-memory ``MudConnection`` for driving ``SessionController`` offline:
/// captures every outbound send and lets the test inject inbound wire bytes.
/// Lets a test exercise the *real* session pipeline + async timer loop (the
/// place dinv's command-queue sends are buffered) without a socket.
final class InMemoryConnection: MudConnection, @unchecked Sendable {
    nonisolated let bytes: AsyncStream<[UInt8]>
    nonisolated let states: AsyncStream<NetworkConnection.State>
    private let bytesContinuation: AsyncStream<[UInt8]>.Continuation
    private let statesContinuation: AsyncStream<NetworkConnection.State>.Continuation
    private let lock = NSLock()
    private var sends: [[UInt8]] = []

    init() {
        (bytes, bytesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, statesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Every outbound chunk as raw bytes, in send order (for asserting telnet
    /// sequences like the anti-idle `IAC NOP` that aren't UTF-8 text).
    var sentBytes: [[UInt8]] {
        lock.withLock { sends }
    }

    /// Every outbound chunk, decoded as UTF-8 and split into lines (the session
    /// appends `\r\n`). Order-preserving.
    var sentLines: [String] {
        lock.withLock {
            sends
                .map { String(decoding: $0, as: UTF8.self) }
                .joined()
                .split(separator: "\r\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
        }
    }

    /// Push server→client bytes into the inbound stream (the harness uses this
    /// to deliver fence echoes / canned responses).
    func injectInbound(_ wireBytes: [UInt8]) {
        bytesContinuation.yield(wireBytes)
    }

    func injectLine(_ text: String) {
        injectInbound(Array((text + "\r\n").utf8))
    }

    func connect(to _: NetworkConnection.Endpoint, timeout _: Duration) async throws {
        statesContinuation.yield(.connecting)
        statesContinuation.yield(.connected)
    }

    func send(_ data: Data) async throws {
        lock.withLock { sends.append([UInt8](data)) }
    }

    func send(_ rawBytes: [UInt8]) async throws {
        lock.withLock { sends.append(rawBytes) }
    }

    func disconnect() async {
        statesContinuation.yield(.disconnected)
        bytesContinuation.finish()
        statesContinuation.finish()
    }
}

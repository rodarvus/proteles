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

    /// Every outbound chunk as a text-command view: telnet IAC sequences are
    /// stripped first (so the out-of-band control bytes a plugin/session writes
    /// on connect — e.g. the Aardwolf `IAC SB 102 …` tag-enables — never glue
    /// onto the next command line), then decoded as UTF-8 and split into lines
    /// (the session appends `\r\n`). Order-preserving. Tests asserting on raw
    /// telnet bytes use ``sentBytes`` instead.
    var sentLines: [String] {
        lock.withLock {
            String(decoding: Self.strippingTelnet(sends.flatMap(\.self)), as: UTF8.self)
                .split(separator: "\r\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
        }
    }

    /// Remove telnet IAC sequences (negotiation `IAC WILL/WONT/DO/DONT <opt>`,
    /// subnegotiation `IAC SB … IAC SE`, escaped `IAC IAC`, and other 2-byte
    /// commands) from a byte stream, leaving only the plain text the client sent.
    private static func strippingTelnet(_ bytes: [UInt8]) -> [UInt8] {
        let iac: UInt8 = 255, sb: UInt8 = 250, se: UInt8 = 240
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            guard bytes[i] == iac else { out.append(bytes[i]); i += 1; continue }
            guard i + 1 < bytes.count else { break } // trailing lone IAC
            switch bytes[i + 1] {
            case iac: out.append(iac); i += 2 // escaped 0xFF
            case sb: // subnegotiation: skip through IAC SE
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == iac && bytes[i + 1] == se) {
                    i += 1
                }
                i += 2
            case 251...254: i += 3 // WILL/WONT/DO/DONT + option
            default: i += 2 // other 2-byte command
            }
        }
        return out
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

import Foundation

/// Anti-idle keep-alive. Aardwolf disconnects a connected-but-quiet session
/// ("Idle time exceeded — see you when you get back!"). Two complementary
/// layers keep us connected:
///   - **Link level** — TCP keepalive (``NetworkConnection/tcpParameters()``),
///     the Network.framework equivalent of MUSHclient's `SIO_KEEPALIVE_VALS`,
///     stops a NAT/firewall dropping the idle socket.
///   - **Application level** (here) — a periodic telnet `IAC NOP` resets the
///     MUD's *command*-idle timer by generating server-side socket activity,
///     without echoing anything or running a command.
extension SessionController {
    /// Telnet `IAC NOP` — a no-op the server reads and discards.
    static let telnetNOP: [UInt8] = [0xFF, 0xF1]

    /// Whether the anti-idle should fire now: outbound has been quiet for at
    /// least `interval`. Pure, so the timing logic is unit-testable.
    nonisolated static func shouldSendKeepAlive(
        now: Date, lastActivity: Date, interval: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(lastActivity) >= interval
    }

    /// (Re)start the anti-idle loop: every ``keepAliveInterval`` seconds, send a
    /// NOP if the link has gone outbound-quiet. Cancelled on disconnect.
    func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            guard let interval = await self?.keepAliveInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.sendKeepAliveIfIdle()
            }
        }
    }

    /// Send the anti-idle NOP when connected and outbound-quiet past the
    /// threshold. `sendRaw` updates ``lastOutboundActivity``, so the NOP itself
    /// re-arms the cadence.
    private func sendKeepAliveIfIdle() async {
        guard keepAliveEnabled,
              state == .connected,
              Self.shouldSendKeepAlive(
                  now: Date(), lastActivity: lastOutboundActivity, interval: keepAliveInterval
              )
        else { return }
        logTranscript(.note, "[keepalive] IAC NOP")
        try? await sendRaw(Self.telnetNOP)
    }
}

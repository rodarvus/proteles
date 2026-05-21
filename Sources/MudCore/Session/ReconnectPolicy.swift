import Foundation

/// How ``SessionController`` should behave when a connection drops
/// **unexpectedly** (a remote close or network failure — never a
/// user-initiated ``SessionController/disconnect()``).
///
/// Backoff is exponential: the delay before attempt *n* (1-based) is
/// `baseDelay * multiplier^(n-1)`, capped at ``maxDelay``. A dead server
/// is therefore retried quickly at first, then ever more slowly, up to
/// ``maxAttempts`` tries before giving up.
public struct ReconnectPolicy: Sendable, Equatable {
    /// When false, an unexpected drop simply surfaces `.disconnected`
    /// and no retry is attempted.
    public var isEnabled: Bool

    /// Maximum number of reconnection attempts before giving up. `0`
    /// means unlimited (retry forever, subject to ``maxDelay``).
    public var maxAttempts: Int

    /// Delay before the first reconnection attempt.
    public var baseDelay: Duration

    /// Upper bound on the backoff delay.
    public var maxDelay: Duration

    /// Growth factor applied per attempt.
    public var multiplier: Double

    public init(
        isEnabled: Bool = true,
        maxAttempts: Int = 8,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        multiplier: Double = 2
    ) {
        self.isEnabled = isEnabled
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
    }

    /// Autoreconnect off. The default for ``SessionController`` so tests
    /// and library users opt in explicitly; the app enables it.
    public static let disabled = ReconnectPolicy(isEnabled: false, maxAttempts: 0)

    /// Sensible production defaults: 1s, 2s, 4s … capped at 30s, 8 tries.
    public static let standard = ReconnectPolicy()

    /// The backoff delay before reconnection attempt `attempt` (1-based),
    /// capped at ``maxDelay``. Values below 1 are treated as the first
    /// attempt.
    public func delay(forAttempt attempt: Int) -> Duration {
        let step = max(attempt, 1) - 1
        let raw = baseDelay.inSeconds * pow(multiplier, Double(step))
        let capped = min(max(raw, 0), maxDelay.inSeconds)
        return .seconds(capped)
    }
}

extension Duration {
    /// This duration expressed as a `Double` number of seconds.
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

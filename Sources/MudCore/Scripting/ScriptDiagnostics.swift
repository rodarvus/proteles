import Foundation

/// One Lua Console event: a script error (with plugin attribution), a line of
/// console output, or the echo of console input. The console window renders
/// the stream; errors also keep their red scrollback note, so the console is
/// a tee, not a redirect.
public struct ScriptDiagnostic: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Equatable {
        /// A script/compile/callback error.
        case error
        /// Output (print/Note/result echoes) from console evaluation.
        case output
        /// The echo of a line the user typed into the console.
        case input
    }

    public let id: UUID
    public let timestamp: Date
    public let severity: Severity
    /// Attribution: the owning plugin's name (or id), `"user"` for user
    /// scripts, or nil for console-local lines.
    public let source: String?
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: Severity,
        source: String?,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.source = source
        self.message = message
    }
}

/// Session-lifetime buffer of ``ScriptDiagnostic`` events for the Lua Console
/// window. Same actor + `subscribe()` shape as ``ChatStore``: the window
/// reads ``recent`` for backfill, then streams.
public actor ScriptDiagnosticsStore {
    /// Ring-buffer cap — plenty of scrollback for a debugging window without
    /// unbounded growth on a long session.
    private static let capacity = 500

    public private(set) var recent: [ScriptDiagnostic] = []
    private var subscribers: [UUID: AsyncStream<ScriptDiagnostic>.Continuation] = [:]

    public init() {}

    /// Append an event and notify observers.
    public func append(_ diagnostic: ScriptDiagnostic) {
        recent.append(diagnostic)
        if recent.count > Self.capacity {
            recent.removeFirst(recent.count - Self.capacity)
        }
        for continuation in subscribers.values {
            continuation.yield(diagnostic)
        }
    }

    /// Clear the buffer (the console's Clear button).
    public func clear() {
        recent = []
    }

    /// Subscribe to new events (no backfill — read ``recent`` first).
    public func subscribe() -> AsyncStream<ScriptDiagnostic> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ScriptDiagnostic>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}

import Foundation

/// Holds the latest ASCII map block captured from Aardwolf's
/// `<MAPSTART>…<MAPEND>` stream (the native ASCII-map feature). Lines keep
/// their styled runs (terrain colours), so the view renders them directly.
///
/// Same actor + `subscribe()` shape as ``ChatStore``/``GMCPStateStore``: the
/// UI reads the current ``map`` for backfill, then streams updates.
public actor MapStore {
    /// The most recent captured map's styled lines (empty until one arrives
    /// / after a clear).
    public private(set) var map: [Line] = []
    private var subscribers: [UUID: AsyncStream<[Line]>.Continuation] = [:]

    public init() {}

    /// Replace the current map and notify observers.
    public func update(_ lines: [Line]) {
        map = lines
        for continuation in subscribers.values {
            continuation.yield(lines)
        }
    }

    /// Clear on a fresh connection.
    public func reset() {
        update([])
    }

    /// Subscribe to map updates (no backfill — the UI reads ``map`` first).
    public func subscribe() -> AsyncStream<[Line]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Line]>.makeStream(bufferingPolicy: .unbounded)
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

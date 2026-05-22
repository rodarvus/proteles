import Foundation

/// Snapshot of the Aardwolf character state assembled from GMCP modules
/// (PLAN.md §5.5). Each field holds the most recent decoded module, or
/// `nil` until one arrives.
public struct GMCPState: Sendable, Equatable {
    public var vitals: CharVitals?
    public var maxStats: CharMaxStats?
    public var status: CharStatus?
    public var worth: CharWorth?
    public var base: CharBase?
    public var room: RoomInfo?
    public var group: GroupInfo?

    public init() {}
}

/// Decodes incoming ``GMCPMessage``s into a typed ``GMCPState`` and
/// publishes snapshots to observers (the status bar, etc.).
///
/// Mirrors ``ScrollbackStore``'s pattern: an actor holding the source of
/// truth, with `subscribe()` returning an `AsyncStream` the UI bridges
/// into observable state. A failed decode leaves the prior state intact
/// (and is not broadcast), so a malformed payload never blanks the UI.
public actor GMCPStateStore {
    public private(set) var state = GMCPState()
    private var subscribers: [UUID: AsyncStream<GMCPState>.Continuation] = [:]

    public init() {}

    /// Apply one GMCP message. Returns true if it updated the state (a
    /// recognised package that decoded cleanly), in which case observers
    /// are notified.
    @discardableResult
    public func apply(_ message: GMCPMessage) -> Bool {
        // Aardwolf sends package names lowercased on the wire
        // (char.vitals, char.maxstats, …); match case-insensitively so we
        // don't depend on the exact casing.
        let changed: Bool = switch message.package.lowercased() {
        case "char.vitals": set(\.vitals, from: message, as: CharVitals.self)
        case "char.maxstats": set(\.maxStats, from: message, as: CharMaxStats.self)
        case "char.status": set(\.status, from: message, as: CharStatus.self)
        case "char.worth": set(\.worth, from: message, as: CharWorth.self)
        case "char.base": set(\.base, from: message, as: CharBase.self)
        case "room.info": set(\.room, from: message, as: RoomInfo.self)
        case "group": set(\.group, from: message, as: GroupInfo.self)
        default: false
        }
        if changed { broadcast() }
        return changed
    }

    /// Subscribe to state snapshots. The current snapshot is delivered
    /// immediately, then each subsequent change. Cancel iteration to
    /// unsubscribe.
    public func subscribe() -> AsyncStream<GMCPState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GMCPState>.makeStream(
            bufferingPolicy: .unbounded
        )
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(state)
        return stream
    }

    /// Clear all state (e.g. on a fresh connection) and notify observers.
    public func reset() {
        state = GMCPState()
        broadcast()
    }

    // MARK: - Private

    private func set<T: Decodable>(
        _ keyPath: WritableKeyPath<GMCPState, T?>,
        from message: GMCPMessage,
        as type: T.Type
    ) -> Bool {
        guard let value = try? message.decode(type) else { return false }
        state[keyPath: keyPath] = value
        return true
    }

    private func broadcast() {
        for continuation in subscribers.values {
            continuation.yield(state)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}

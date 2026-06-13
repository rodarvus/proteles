import Foundation

/// Snapshot of the Aardwolf character state assembled from GMCP modules
/// (ARCHITECTURE.md §5.5). Each field holds the most recent decoded module, or
/// `nil` until one arrives.
public struct GMCPState: Sendable, Equatable {
    public var vitals: CharVitals?
    public var maxStats: CharMaxStats?
    public var stats: CharStats?
    public var status: CharStatus?
    public var worth: CharWorth?
    public var base: CharBase?
    public var room: RoomInfo?
    public var group: GroupInfo?
    /// When the most recent Aardwolf tick was witnessed (a `comm.tick` GMCP
    /// broadcast). `nil` until the first tick — "a tick must be witnessed
    /// before the next tick can be predicted" (cf. Aardwolf_Tick_Timer).
    public var lastTick: Date?

    public init() {}

    /// Aardwolf's nominal tick length. Fixed at 30s to match the reference
    /// `Aardwolf_Tick_Timer` (it does not measure the interval); each
    /// `comm.tick` re-anchors the countdown, so the readout self-corrects.
    public static let tickInterval: TimeInterval = 30

    /// Seconds until the next tick: `lastTick + interval - now`, matching the
    /// reference's `last_tick + tick_length - os.time()`. **Not** clamped — a
    /// late tick shows a brief negative until the next `comm.tick` resets the
    /// anchor (same as the reference's `%2i` formatting).
    public static func secondsToNextTick(
        lastTick: Date,
        now: Date = Date(),
        interval: TimeInterval = tickInterval
    ) -> Int {
        Int(lastTick.addingTimeInterval(interval).timeIntervalSince(now))
    }
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
        // Aardwolf sends package names lowercased on the wire (char.vitals,
        // char.maxstats, …); match case-insensitively. comm.tick is handled by
        // the TickTimer plugin via setLastTick, not decoded here.
        let changed = decodeModule(message.package.lowercased(), message)
        if changed { broadcast() }
        return changed
    }

    /// Set (or clear) the witnessed-tick anchor and notify observers. Driven by
    /// the native `TickTimer` plugin's `comm.tick` handling (via the
    /// `updateTick` effect) rather than `apply`, so the plugin's enabled flag
    /// gates it — see ``GMCPState/secondsToNextTick``.
    public func setLastTick(_ date: Date?) {
        guard state.lastTick != date else { return }
        state.lastTick = date
        broadcast()
    }

    /// Decode a character/room/group module into its state slot. Returns
    /// whether it updated the state (recognised package, clean decode).
    private func decodeModule(_ package: String, _ message: GMCPMessage) -> Bool {
        switch package {
        case "char.vitals": set(\.vitals, from: message, as: CharVitals.self)
        case "char.maxstats": set(\.maxStats, from: message, as: CharMaxStats.self)
        case "char.stats": set(\.stats, from: message, as: CharStats.self)
        case "char.status": set(\.status, from: message, as: CharStatus.self)
        case "char.worth": set(\.worth, from: message, as: CharWorth.self)
        case "char.base": set(\.base, from: message, as: CharBase.self)
        case "room.info": set(\.room, from: message, as: RoomInfo.self)
        case "group": set(\.group, from: message, as: GroupInfo.self)
        default: false
        }
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

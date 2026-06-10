import Foundation

/// Holds the continent bigmaps captured from Aardwolf's `{bigmap}` stream
/// (the native continent-map feature), keyed by continent zone id. Lines are
/// border-stripped and keep their styled runs, so the view renders each
/// character as a coloured cell with the player marker at the GMCP
/// `coord.x`/`coord.y` cell.
///
/// Same actor + `subscribe()` shape as ``MapStore``: the UI reads
/// ``map(forZone:)`` for backfill, then streams updates. Maps cache for the
/// session (the reference Bigmap plugin persists them across sessions in
/// plugin variables; continents change rarely, so per-session is enough — a
/// fresh map is one `bigmap` request away).
public actor BigmapStore {
    /// One captured continent map.
    public struct ContinentMap: Sendable, Equatable {
        public let zone: Int
        public let name: String
        public let lines: [Line]

        public init(zone: Int, name: String, lines: [Line]) {
            self.zone = zone
            self.name = name
            self.lines = lines
        }
    }

    private var maps: [Int: ContinentMap] = [:]
    private var subscribers: [UUID: AsyncStream<ContinentMap>.Continuation] = [:]

    public init() {}

    /// The cached map for a continent zone, if one was captured this session.
    public func map(forZone zone: Int) -> ContinentMap? {
        maps[zone]
    }

    /// Store a captured map and notify observers.
    public func update(_ map: ContinentMap) {
        maps[map.zone] = map
        for continuation in subscribers.values {
            continuation.yield(map)
        }
    }

    /// Clear on a fresh connection.
    public func reset() {
        maps = [:]
    }

    /// Subscribe to newly captured maps (no backfill — read ``map(forZone:)``
    /// first).
    public func subscribe() -> AsyncStream<ContinentMap> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ContinentMap>.makeStream(bufferingPolicy: .unbounded)
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

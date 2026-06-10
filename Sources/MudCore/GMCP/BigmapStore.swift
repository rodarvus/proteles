import Foundation

/// Holds the continent bigmaps captured from Aardwolf's `{bigmap}` stream
/// (the native continent-map feature), keyed by continent zone id. Lines are
/// border-stripped and keep their styled runs, so the view renders each
/// character as a coloured cell with the player marker at the GMCP
/// `coord.x`/`coord.y` cell.
///
/// Same actor + `subscribe()` shape as ``MapStore``: the UI reads
/// ``map(forZone:)`` for backfill, then streams updates. Captures persist to
/// disk (#54: `State/bigmaps.json`) so stepping overland shows the continent
/// *instantly* on a fresh launch; the native plugin still re-fetches each
/// continent once per session, so a map Aardwolf changed self-heals — the
/// persistence removes the blank "fetching…" gap, not the refresh.
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
    /// On-disk location (nil = memory-only, e.g. tests) + lazy one-shot load.
    private let url: URL?
    private var loadedFromDisk = false

    /// `url` is where captures persist; nil keeps the store memory-only.
    public init(url: URL? = nil) {
        self.url = url
    }

    /// The default persistence location: `State/bigmaps.json` under the
    /// Proteles home (test runs redirect the home to a sandbox).
    public static func defaultStoreURL() -> URL? {
        try? ProtelesPaths.stateDirectory().appendingPathComponent("bigmaps.json")
    }

    /// The cached map for a continent zone — this session's capture, else
    /// the persisted one from an earlier session.
    public func map(forZone zone: Int) -> ContinentMap? {
        loadIfNeeded()
        return maps[zone]
    }

    /// Store a captured map, notify observers, and persist.
    public func update(_ map: ContinentMap) {
        loadIfNeeded()
        maps[map.zone] = map
        for continuation in subscribers.values {
            continuation.yield(map)
        }
        persist()
    }

    /// Clear on a fresh connection. The DISK cache intentionally survives
    /// (#54 — it exists to outlive sessions); only in-memory state resets so
    /// reconnect behaviour matches a fresh launch.
    public func reset() {
        maps = [:]
        loadedFromDisk = false
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

    // MARK: - Persistence (#54)

    /// The on-disk shape: a slim DTO per line (text + styled runs) — a
    /// bigmap line's `LineID`/timestamp carry no meaning, so they aren't
    /// stored.
    private struct StoredLine: Codable {
        let text: String
        let runs: [StyledRun]
    }

    private struct StoredMap: Codable {
        let zone: Int
        let name: String
        let lines: [StoredLine]
    }

    private func loadIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredMap].self, from: data)
        else { return }
        for entry in stored where maps[entry.zone] == nil {
            maps[entry.zone] = ContinentMap(
                zone: entry.zone,
                name: entry.name,
                lines: entry.lines.map { Line(id: LineID(0), text: $0.text, runs: $0.runs) }
            )
        }
    }

    private func persist() {
        guard let url else { return }
        let stored = maps.values.sorted { $0.zone < $1.zone }.map { map in
            StoredMap(
                zone: map.zone,
                name: map.name,
                lines: map.lines.map { StoredLine(text: $0.text, runs: $0.runs) }
            )
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

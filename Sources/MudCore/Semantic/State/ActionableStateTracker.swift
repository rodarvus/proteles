import Foundation

/// Keeps ``ActionableState`` current from the inbound line stream and GMCP
/// (S0b item 1, #84). Pure: the engine holds one and feeds it at S0a's
/// seams, so state costs no actor hop (`docs/plans/S0B_ITEM1_PROPOSAL.md`).
///
/// Lines are ingested **raw**, before any gag and whatever scripts are
/// doing: state records what the game sent, and tag lines are hidden by the
/// norm (D-128's reasoning for structural events applies here too).
public struct ActionableStateTracker: Sendable {
    /// What one ingest changed.
    public struct Change: Sendable, Equatable {
        /// Anything in the state changed, feed status included: publish a
        /// snapshot to the UI.
        public var state = false
        /// The entities that changed: tell the native plugins. Never set by
        /// a feed-status change alone.
        public var entities: Set<ActionableState.Entity> = []

        public static let none = Change()

        mutating func merge(_ other: Change) {
            state = state || other.state
            entities.formUnion(other.entities)
        }
    }

    /// How often a count-only change is published: a repeated tag line or
    /// GMCP packet bumps its feed's ``ActionableState/FeedStatus/arrivals``
    /// but reports a change only once this long has passed since the last
    /// one. Any other change publishes at once, carrying the counts with it.
    public static let countRefresh: TimeInterval = 5

    public internal(set) var state = ActionableState()
    private var collector = TagBlockCollector()
    /// Whole-room `consider` output being read (item 2).
    var considerWindow = ConsiderWindow()
    /// The room named lists are bound to: `room.info`'s num and zone.
    var room: (num: Int?, area: String?) = (nil, nil)
    /// A block or a consider window is open, so any line may change state.
    /// Stored, not computed: the engine reads it on every line through its
    /// actor property, and a stored field is read without copying the
    /// tracker (item 2's B6, `docs/plans/S0B_ITEM2_PROPOSAL.md` §9).
    public internal(set) var isReading = false
    /// When the last reported change happened, by the input's own clock.
    private var lastReported: Date?
    /// Arrivals counted since the last reported change.
    private var countsPending = false

    public init() {}

    /// Feed one inbound line. A line that is not a tag outside a block costs
    /// one first-byte check, one "is a block open" check and one "is a
    /// consider window open" check; a tag line is parsed once
    /// (``FeedMarker``) for both the collector and the tag-line feeds.
    public mutating func ingest(_ line: Line) -> Change {
        let marker = FeedMarker.parse(line.text)
        guard marker != nil || isReading else { return .none }
        defer { isReading = collector.isCollecting || considerWindow.isOpen }
        var change = Change()
        if considerWindow.isOpen, marker == nil {
            change.merge(ingestConsider(line))
        }
        guard marker != nil || collector.isCollecting else { return reported(change, at: line.timestamp) }
        let outcome = collector.ingest(line, marker: marker)
        if let drop = outcome.dropped {
            state.recordIncomplete(drop)
            change.state = true
        }
        if let block = outcome.completed {
            state.countBlock(block.feed, at: line.timestamp)
            change.state = true
            change.merge(ingestBlock(block, at: line.timestamp))
        }
        if let marker, marker.feed.kind == .tagLine, !marker.isClosing {
            change.state = countArrival(marker.feed, at: line.timestamp) || change.state
        }
        return reported(change, at: line.timestamp)
    }

    /// Feed one GMCP package with its payload: the arrival count, and for
    /// `room.info` the room named occupants are bound to.
    public mutating func ingest(gmcpPackage package: String, json: String, at date: Date = Date()) -> Change {
        var change = ingest(gmcpPackage: package, at: date)
        guard package.lowercased() == "room.info",
              let room = try? JSONDecoder().decode(RoomKey.self, from: Data(json.utf8))
        else { return change }
        change.merge(ingest(room: room.num, area: room.zone))
        return change
    }

    /// The two `room.info` fields named occupants are bound by.
    private struct RoomKey: Decodable {
        let num: Int?
        let zone: String?
    }

    /// Feed `room.info`'s room number and zone. Leaving a room drops its
    /// named list.
    public mutating func ingest(room num: Int?, area: String?) -> Change {
        guard num != room.num || area != room.area else { return .none }
        room = (num, area)
        guard let named = state.occupants?.named, named.room != num else { return .none }
        state.occupants?.named = nil
        return Change(state: true, entities: [.occupants])
    }

    /// Whether `line` can change anything: a tag line, or any line while a
    /// block is open. The rest return ``Change/none`` from ``ingest(_:)``;
    /// the engine checks this first so they skip the probe as well.
    public func mayChange(on line: Line) -> Bool {
        line.text.utf8.first == UInt8(ascii: "{") || isReading
    }

    /// Feed one GMCP package name (the payload is the item that parses it).
    public mutating func ingest(gmcpPackage package: String, at date: Date = Date()) -> Change {
        guard let feed = ActionableState.Feed(rawValue: package.lowercased()), feed.kind == .gmcp
        else { return .none }
        return reported(Change(state: countArrival(feed, at: date)), at: date)
    }

    /// Forget everything (a fresh connection): every feed reads unseen. The
    /// keyword book stays: it isn't per-connection.
    public mutating func reset() {
        let keywords = state.keywords
        state = ActionableState()
        state.keywords = keywords
        collector.reset()
        considerWindow.reset()
        room = (nil, nil)
        isReading = false
        lastReported = nil
        countsPending = false
    }

    // MARK: - Arrival counts

    /// Count an arrival; returns whether it was the feed's first sighting.
    private mutating func countArrival(_ feed: ActionableState.Feed, at date: Date) -> Bool {
        countsPending = true
        return state.countArrival(feed, at: date)
    }

    /// `change`, also reporting pending counts once ``countRefresh`` has
    /// passed. Every reported change carries the counts, so it clears them.
    private mutating func reported(_ change: Change, at date: Date) -> Change {
        var change = change
        let refreshDue = lastReported.map { date.timeIntervalSince($0) >= Self.countRefresh } ?? false
        if countsPending, refreshDue { change.state = true }
        if change.state {
            lastReported = date
            countsPending = false
        }
        return change
    }
}

import Foundation

/// The actionable-state model (S0b, GitHub #84; D-121, D-129): what exists
/// *now* and the handle each thing is acted on by. The durable, replaceable
/// half of the semantic layer, beside S0a's ephemeral events.
///
/// Item 1 is the frame: the feed table only. Each later item adds its
/// entity's slot (occupants, items, spells, …) and a case to ``Entity``
/// (`docs/plans/S0B_ITEM1_PROPOSAL.md`).
///
/// ## Feed absent is not empty
///
/// The model never presents missing data as truth. Every entity reads its
/// feed's ``FeedStatus``: a feed not seen this connection means the entity
/// is *unknown*, while a feed that is seen and empty (a `{roomchars}` block
/// with no lines) means it *is* empty. S0b switches no feed on (D-123);
/// whatever the player's settings and plugins enable is what fills it.
///
/// ## Reference, don't copy
///
/// Room, vitals and status stay owned by `GMCPState` and the Mapper
/// (D-129); the model records only that their feeds were seen.
public struct ActionableState: Sendable, Equatable {
    /// The feeds S0b reads, as a closed list.
    public enum Feed: String, CaseIterable, Sendable {
        /// Tag blocks: `{x}` … `{/x}`.
        case roomchars, roomobjs, invdata, eqdata, spellheaders
        /// Single tagged lines.
        case exits, invmon
        // GMCP packages (raw values are the lowercased wire names).
        case roomInfo = "room.info"
        case charVitals = "char.vitals"
        case charStatus = "char.status"

        /// How a feed arrives.
        public enum Kind: Sendable {
            case tagBlock, tagLine, gmcp
        }

        public var kind: Kind {
            switch self {
            case .roomchars, .roomobjs, .invdata, .eqdata, .spellheaders: .tagBlock
            case .exits, .invmon: .tagLine
            case .roomInfo, .charVitals, .charStatus: .gmcp
            }
        }

        /// The feed a tag marker name opens or carries, when it is one of
        /// S0b's (`roomchars` → `.roomchars`); `nil` for any other marker.
        public init?(marker: String) {
            guard let feed = Feed(rawValue: marker), feed.kind != .gmcp else { return nil }
            self = feed
        }
    }

    /// One entity a consumer can be told changed. Items 2–7 add the cases
    /// (occupants, items, spells, …); the frame has none, so a change in
    /// item 1 is always a feed-status change only.
    public enum Entity: Hashable, Sendable {}

    /// Whether, and how, a feed has been seen this connection.
    public struct FeedStatus: Sendable, Equatable {
        /// When the feed was first seen this connection; `nil` while unseen.
        public var since: Date?
        /// Completed blocks (tag-block feeds only).
        public var blocks = 0
        /// Blocks dropped as incomplete (tag-block feeds only).
        public var incompleteBlocks = 0
        /// The most recent incomplete block, if any.
        public var lastIncomplete: TagBlockCollector.Drop?
        /// Lines or packets received this connection (tag-line and GMCP
        /// feeds only). The UI hears a new count at most every
        /// ``ActionableStateTracker/countRefresh``.
        public var arrivals = 0

        public init() {}

        public var isSeen: Bool {
            since != nil
        }
    }

    /// Every feed's status; a feed absent from the map has never been seen.
    public private(set) var feeds: [Feed: FeedStatus] = [:]

    public init() {}

    /// The status of `feed` (unseen when it has never arrived).
    public func status(of feed: Feed) -> FeedStatus {
        feeds[feed] ?? FeedStatus()
    }

    /// Record that `feed` arrived at `date`. Returns whether that changed
    /// anything — only the first sighting does.
    @discardableResult
    mutating func markSeen(_ feed: Feed, at date: Date) -> Bool {
        guard feeds[feed]?.since == nil else { return false }
        feeds[feed, default: FeedStatus()].since = date
        return true
    }

    /// Count one tag line or GMCP packet for `feed`. Returns whether it was
    /// the feed's first sighting.
    mutating func countArrival(_ feed: Feed, at date: Date) -> Bool {
        let first = markSeen(feed, at: date)
        feeds[feed, default: FeedStatus()].arrivals += 1
        return first
    }

    /// Count a completed block for `feed`.
    mutating func countBlock(_ feed: Feed, at date: Date) {
        markSeen(feed, at: date)
        feeds[feed, default: FeedStatus()].blocks += 1
    }

    /// Record a block dropped as incomplete.
    mutating func recordIncomplete(_ drop: TagBlockCollector.Drop) {
        markSeen(drop.feed, at: drop.at)
        feeds[drop.feed, default: FeedStatus()].incompleteBlocks += 1
        feeds[drop.feed, default: FeedStatus()].lastIncomplete = drop
    }
}

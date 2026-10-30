import Foundation

/// Assembles Aardwolf's tag blocks — `{roomchars}` … `{/roomchars}`,
/// `{invdata 123}` … `{/invdata}`, `{spellheaders hsp}` … `{/spellheaders}` —
/// from the line stream, for the actionable-state model (S0b item 1, #84).
///
/// It only **observes**: every line inside a block still reaches triggers,
/// plugins and the output exactly as before. Blocks are collected for the
/// tag-block feeds in ``ActionableState/Feed`` only.
///
/// ## Edge rules
///
/// In October 2026's 114 recorded sessions every block that opened also
/// closed (`docs/plans/S0B_ITEM1_PROPOSAL.md` §2), so these guard against
/// something the corpus has never shown, and each drop is reported rather
/// than silently swallowed:
///
/// - a block ends at its own closing marker;
/// - another collected opening or closing marker while a block is open
///   drops the open block as ``Drop/Reason/interrupted`` (the new opening
///   then starts its own block);
/// - a block reaching ``lineCap`` lines is dropped as
///   ``Drop/Reason/overflow``; its stray closing marker is then ignored.
public struct TagBlockCollector: Sendable {
    /// A completed block: the feed, the opening marker's arguments (`hsp`
    /// for `{spellheaders hsp}`, a container id for `{invdata 123}`, empty
    /// for most), and the lines between the markers.
    public struct Block: Sendable, Equatable {
        public let feed: ActionableState.Feed
        public let arguments: String
        public let lines: [Line]
    }

    /// A block dropped as incomplete.
    public struct Drop: Sendable, Equatable {
        public enum Reason: String, Sendable {
            case interrupted, overflow
        }

        public let feed: ActionableState.Feed
        public let reason: Reason
        /// The timestamp of the line that ended it.
        public let at: Date
        /// Lines collected before the drop.
        public let lineCount: Int
    }

    /// What one line did to the collector.
    public struct Outcome: Sendable, Equatable {
        public var completed: Block?
        public var dropped: Drop?
        /// The feed whose block this line opened.
        public var opened: ActionableState.Feed?

        public static let none = Outcome()
    }

    /// The longest block allowed: about three times the corpus maximum
    /// (619 lines, a `{spellheaders}` list).
    public static let lineCap = 2000

    /// The block being collected, if any.
    private struct OpenBlock {
        let feed: ActionableState.Feed
        let arguments: String
        var lines: [Line] = []
    }

    private var open: OpenBlock?

    public init() {}

    /// Whether a block is open — the per-line fast path's second check.
    public var isCollecting: Bool {
        open != nil
    }

    /// Feed one line. Lines that are not tag markers outside a block return
    /// ``Outcome/none`` after a single first-byte check.
    public mutating func ingest(_ line: Line) -> Outcome {
        ingest(line, marker: FeedMarker.parse(line.text))
    }

    /// Feed one line whose feed marker the caller has already parsed (the
    /// tracker parses each line once for both of its checks).
    mutating func ingest(_ line: Line, marker: FeedMarker?) -> Outcome {
        if let marker, marker.feed.kind == .tagBlock {
            return ingestMarker(marker, at: line.timestamp)
        }
        guard var block = open else { return .none }
        // Release `open`'s reference first so the append mutates the array
        // in place rather than copying it (quadratic in block length).
        open = nil
        block.lines.append(line)
        if block.lines.count >= Self.lineCap {
            return Outcome(dropped: Drop(
                feed: block.feed, reason: .overflow, at: line.timestamp, lineCount: block.lines.count
            ))
        }
        open = block
        return .none
    }

    /// Forget any open block (a fresh connection).
    public mutating func reset() {
        open = nil
    }

    // MARK: - Markers

    private mutating func ingestMarker(_ marker: FeedMarker, at date: Date) -> Outcome {
        var outcome = Outcome()
        if let block = open {
            open = nil
            if marker.isClosing, marker.feed == block.feed {
                outcome.completed = Block(feed: block.feed, arguments: block.arguments, lines: block.lines)
                return outcome
            }
            outcome.dropped = Drop(
                feed: block.feed,
                reason: .interrupted,
                at: date,
                lineCount: block.lines.count
            )
        }
        if !marker.isClosing {
            open = OpenBlock(feed: marker.feed, arguments: marker.arguments)
            outcome.opened = marker.feed
        }
        return outcome
    }
}

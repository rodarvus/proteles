import Foundation

/// Who and what is in the room (S0b item 2, #84; `docs/plans/S0B_ITEM2_PROPOSAL.md`).
///
/// Two layers, because no one feed gives both:
///
/// - **Presence** (``present``), from `{roomchars}`: one line per occupant —
///   its *room description* ("A sunrise mallard gracefully weaves its
///   way…"), not its name — with aura flags. Always current while the feed
///   is on. A keyword can't be derived from it: only 44% of considered names
///   appear in their description.
/// - **Names** (``named``), from output that prints short names: `consider`
///   (with tiers) or the `Right here you see:` section of `{scan}`. Kept for
///   the room it was taken in, dropped on leaving it.
///
/// The two are paired by **count, never position**: when the named mobs
/// number as many as the present non-players, the names are complete
/// (S&D's smartscan check); otherwise someone arrived, died or doesn't scan.
/// Players are never targets: they are counted, never named.
public struct Occupants: Sendable, Equatable {
    /// The occupants of the latest `{roomchars}` block, in order; `nil`
    /// while `{roomchars}` hasn't been seen (names alone don't make presence
    /// known).
    public var present: [Occupant]?
    /// When ``present`` or ``named`` last changed.
    public var since: Date
    /// The latest name list for this room, if a name source has spoken.
    public var named: NamedOccupants?

    public init(present: [Occupant]?, since: Date, named: NamedOccupants? = nil) {
        self.present = present
        self.since = since
        self.named = named
    }

    /// The present non-players: the only candidates for targeting.
    public var mobs: [Occupant]? {
        present?.filter { !$0.isPlayer }
    }

    public var playerCount: Int? {
        present?.count(where: \.isPlayer)
    }

    /// Whether ``named`` accounts for every present mob; false while either
    /// is unknown.
    public var isNamedComplete: Bool {
        guard let named, let mobs else { return false }
        return named.mobs.count == mobs.count
    }
}

/// One `{roomchars}` line.
public struct Occupant: Sendable, Equatable {
    /// Aura flags without parentheses, in order (`["P", "F", "W", "OPK"]`).
    public let flags: [String]
    public let isPlayer: Bool
    /// The text after the flags: a mob's room description, or a player's
    /// pretitle, name and title (unparseable as a name, so never used).
    public let description: String

    public init(flags: [String], description: String) {
        self.flags = flags
        isPlayer = AuraFlags.isPlayer(flags)
        self.description = description
    }

    /// Parse one `{roomchars}` line.
    static func parse(_ text: String) -> Occupant {
        let split = AuraFlags.split(Substring(text))
        return Occupant(flags: split.flags, description: String(split.rest))
    }
}

/// The mobs a name source listed for one room.
public struct NamedOccupants: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// `consider`: names, flags and tiers; sees noscan mobs.
        case consider
        /// `{scan}`'s `Right here you see:`: names and flags; misses noscan mobs.
        case scan
    }

    public let source: Source
    /// The room (`room.info` num) and area it was taken in.
    public let room: Int?
    public let area: String?
    public let at: Date
    public var mobs: [NamedOccupant]
}

/// A named mob and the keyword to target it by.
public struct NamedOccupant: Sendable, Equatable {
    /// As the game printed it ("A kobold miner").
    public let name: String
    public let flags: [String]
    /// The difficulty tier, when the source was `consider`.
    public let tier: ConsiderTier?
    public let unattackable: ConsiderLine.Unattackable?
    public var keyword: MobKeywordBook.Resolved
}

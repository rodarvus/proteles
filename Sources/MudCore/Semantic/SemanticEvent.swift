import Foundation

/// A classified thing that *happened* in the game — the S0a half of the semantic
/// layer (GitHub #82, D-118/D-120).
///
/// Proteles historically ran three independent matchers over the same text
/// (``SoundEventClassifier`` hardcoded, ``NotificationMatcher`` user-extensible,
/// `TriggerEngine` GUI-authored) plus a tag lexer that stripped without routing.
/// They are partial implementations of this one type. A ``SemanticEvent`` is
/// produced once, at a single classification point, and fanned out to every
/// consumer — sound, notifications, speech, and later the lens surfaces.
///
/// ## Scope: events, not state
///
/// The lens journey decomposition (`docs/plans/LENS_DESIGN.md`) found that of the
/// twelve entities the journeys need, exactly **one** is event-shaped — combat
/// flow. Everything else (occupants, exits, items, spells, channels, vitals) is
/// durable *state* and belongs to S0b, not here. So this type deliberately
/// covers a narrow surface: combat, the vocabulary the shipped soundpack already
/// proves, and the **transitions** that update S0b's entities.
///
/// ## What is deliberately absent
///
/// D-118 sketched this type as "category, severity, captured payload, source".
/// **There is no `severity`.** Its only named consumers were speech priority
/// tiers and notification urgency, both of which live in the deferred
/// accessibility work (D-120, `#9`). Adding it now would be a field with no
/// reader — exactly the speculative modelling D-120 guards against. It is a
/// two-line addition if a consumer appears.
public struct SemanticEvent: Sendable, Equatable {
    /// Coarse grouping, used for *policy*: which category a player mutes, which
    /// a lens subscribes to, which speech tier something belongs in. Kept small
    /// deliberately — every case below has a named consumer today.
    public enum Category: String, Sendable, Equatable, CaseIterable {
        /// Fighting, kills, deaths. The only genuinely event-shaped entity in
        /// the lens decomposition.
        case combat
        /// Levels, experience, skill gains, tier/superhero milestones.
        case progression
        /// Spells and skills landing, wearing off, failing, or on cooldown —
        /// `{affon}` / `{affoff}` / `{sfail}` / `{recon}` / `{recoff}`.
        case affect
        /// Items gained, lost, or found — `{invmon}` and the soundpack's
        /// find/bonus events. Updates S0b's item entities.
        case inventory
        /// Quests, campaigns, global quests, repops, warfare — the world moving
        /// around the player.
        case world
        /// Channels, tells, says, socials. Anything another *person* said.
        case communication
        /// Grouping and following.
        case group
        /// Server broadcasts addressed to everyone rather than to the player:
        /// `INFO:`, restores, auctions, market, notes.
        case system
    }

    /// Where the classification came from, in the tiering
    /// `docs/AARDWOLF_DATA_FEEDS.md` establishes: **GMCP > tags > line
    /// patterns**. Carried on the event itself so a consumer — or a test — can
    /// tell a structural fact from a guess about configurable prose.
    public enum Source: Sendable, Equatable {
        /// Parsed from a GMCP package. Immune to every display setting.
        case gmcp(package: String)
        /// Parsed from an Aardwolf tag block. Fixed shape, but the family has
        /// to be enabled (see the feeds doc §3).
        case tag(family: String)
        /// Matched from displayed text. Fragile: subject to `damage 0–6`,
        /// `shortflags`, `spamreduce` and friends. The identifier names the
        /// rule so a failure is traceable to it.
        case pattern(rule: String)

        /// Ranking for the ordering rule — lower is more durable. Lets a
        /// consumer prefer a GMCP-derived event over a pattern-derived one for
        /// the same moment, and lets tests assert we did not regress a feed to
        /// a weaker tier.
        public var durability: Int {
            switch self {
            case .gmcp: 0
            case .tag: 1
            case .pattern: 2
            }
        }
    }

    /// The coarse grouping, for policy.
    public let category: Category
    /// The specific event, for mapping — the soundpack's cue table is keyed on
    /// exactly this, so the 69 reference names (`tell`, `level_up`, `zone_repop`
    /// …) are the vocabulary. Both this and ``category`` exist because they have
    /// different readers: cue lookup needs the name, muting and subscription
    /// need the group.
    public let name: String
    /// Where it came from, and therefore how much to trust it.
    public let source: Source
    /// Captured values, keyed by capture name. Deliberately stringly-typed: the
    /// two existing producers (the soundpack's regex captures and
    /// `NotificationMatcher`'s rules) already work this way, and a typed payload
    /// per event would be a large modelling exercise with no reader asking for
    /// it yet.
    public let payload: [String: String]

    public init(
        category: Category,
        name: String,
        source: Source,
        payload: [String: String] = [:]
    ) {
        self.category = category
        self.name = name
        self.source = source
        self.payload = payload
    }
}

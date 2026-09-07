import Foundation

/// The routing half of `AardwolfTags` — S0a item 5 (GitHub #82; D-118
/// "`AardwolfTags` promoted to a tag-family router"; D-121 "built here; S0b
/// extends it to the entity-feed families"; D-123 for the rule below).
///
/// ## The rule
///
/// **A tag family is routed only for data GMCP does not carry.** Comms are
/// GMCP (`comm.channel` carries every channel kind, including the player's own
/// sends), so `CHANNELS`/`TELLS`/`SAYS` are never enabled, routed or parsed.
/// Affects, recoveries, cast failures and skill gains have no GMCP package at
/// all — Aardwolf publishes them only as `SPELLUPS`/`SKILLGAINS` tags — so
/// those are the families this item routes. The entity feeds (`roomchars`,
/// `roomobjs`, `exits`, `invmon`, …) pass the same rule and are S0b's.
///
/// ## What routing is, and is not
///
/// Routing turns a tagged line into a `SemanticEvent` with source
/// `.tag(family:)`, the structural tier between GMCP and prose. It is
/// independent of *display*: `displayLine(for:)`, the machine-data hiding and
/// the "clean tag markers" preference are untouched, so a hidden `{affoff}58`
/// still yields its event and a routed line is still hidden.
///
/// Nothing here is asynchronous. The router classifies lines the game already
/// sends; it initiates no command and awaits no completion. (dinv's fence-and-
/// spin-wait machinery exists because dinv *sends* `invdata`/`eqdata` and must
/// detect when their output ends — a different problem, deliberately not
/// copied; see `docs/plans/S0A_ITEM5_PROPOSAL.md` §2.1.)
///
/// Grammar and semantics come from `help tags` / `help spelltags` and the
/// recordings corpus (`docs/AARDWOLF_DATA_FEEDS.md` §3–§4), never intuition:
/// a payload that does not match the documented shape yields no event.
public extension AardwolfTags {
    /// The closed list of families the bare `tags` command reports — 27, from
    /// `session-20260822-141044.log`. Naming them all here is what lets S0b add
    /// parsers rather than a mechanism.
    enum Family: String, CaseIterable, Sendable {
        case bigmap, channels, coords, editors, equip, exits, helps, inv, map
        case mapexits, mapnames, quiet, roomdescs, roomnames, says, score
        case skillgains, spellups, tells, telopts, mapdata, roomchars, roomobjs
        case scan, repop, commands
        case `where`
    }

    /// A marker recognised at the start of a line.
    struct Marker: Equatable, Sendable {
        /// The marker name as written, without braces or `/` (`affon`, `rname`).
        public let name: String
        /// The family the marker belongs to, when documented. Command output
        /// that is tagged regardless of the `tags` command (`invdata`, `eqdata`,
        /// `invitem`, `invmon`, `keyring`, `spellheaders`, …) belongs to none.
        public let family: Family?
        /// `{/roomchars}` — the end of a block.
        public let isClosing: Bool
        /// Everything after the marker: `614,1200` for `{affon}614,1200`, the
        /// room name for `{rname}The top of the tower`.
        public let payload: String
    }

    /// Marker → family, for every marker `help tags` documents or the corpus
    /// shows. `MAP` uses `<MAPSTART>`/`<MAPEND>`, not braces, and `QUIET`,
    /// `TELOPTS`, `MAPDATA`, `MAPEXITS`, `MAPNAMES`, `REPOP`, `COMMANDS`,
    /// `WHERE` have no observed brace marker, so they are absent on purpose.
    static let familiesByMarker: [String: Family] = [
        "bigmap": .bigmap,
        "chan": .channels,
        "coords": .coords,
        "edit": .editors,
        "equip": .equip,
        "exits": .exits,
        "help": .helps, "helpbody": .helps, "helpkeywords": .helps, "helpsearch": .helps,
        "inventory": .inv,
        "rdesc": .roomdescs,
        "rname": .roomnames,
        "say": .says,
        "score": .score,
        "skillgain": .skillgains,
        "affon": .spellups, "affoff": .spellups, "recon": .spellups, "recoff": .spellups,
        "sfail": .spellups,
        "tell": .tells,
        "roomchars": .roomchars,
        "roomobjs": .roomobjs,
        "scan": .scan
    ]

    /// The marker at the start of `text`, if any. Same grammar as the display
    /// half (`leadingTag(in:)`), so routing and display never disagree about
    /// what is a tag.
    static func marker(in text: String) -> Marker? {
        guard let tag = leadingTag(in: text) else { return nil }
        let utf16 = text.utf16
        let payloadStart = utf16.index(utf16.startIndex, offsetBy: tag.utf16Length)
        return Marker(
            name: tag.name,
            family: familiesByMarker[tag.name],
            isClosing: text.hasPrefix("{/"),
            payload: String(utf16[payloadStart...]) ?? ""
        )
    }

    // MARK: - Events (S0a: the SPELLUPS and SKILLGAINS families)

    /// Every event name the router can emit, for the vocabulary's totality
    /// tests. Categories live in ``SemanticEventVocabulary``.
    static let eventNames: Set<String> = [
        "affect_on", "affect_off", "recovery_on", "recovery_off", "cast_failed", "skill_gain"
    ]

    /// `{sfail}` reason codes, verbatim from `help spelltags` (2021-03-27).
    /// Code 7 is absent from the help and stays absent here: an undocumented
    /// code resolves to `unknown`, never to a neighbour.
    static let castFailureReasons: [Int: String] = [
        1: "lost_concentration",
        2: "already_affected",
        3: "blocked_by_recovery",
        4: "not_enough_mana",
        5: "nocast_room",
        6: "cannot_concentrate",
        8: "unknown_spell",
        9: "self_only_on_other",
        10: "resting",
        11: "disabled",
        12: "not_enough_moves"
    ]

    /// The events a tagged line carries — `[]` for any line that is not one of
    /// the six event tags, including entity-feed markers (S0b) and closing
    /// markers. Numbers ride as strings, like the rest of the layer.
    static func events(forTagged text: String) -> [SemanticEvent] {
        guard text.utf8.first == UInt8(ascii: "{"),
              let marker = marker(in: text), !marker.isClosing,
              let family = marker.family, family == .spellups || family == .skillgains
        else { return [] }
        let fields = marker.payload.split(separator: ",", omittingEmptySubsequences: false)
            .map { Int(String($0)) }
        guard fields.allSatisfy({ $0 != nil }) else { return [] }
        let numbers = fields.compactMap(\.self)
        guard let (name, payload) = routed(marker: marker.name, numbers: numbers) else { return [] }
        return [SemanticEvent(
            category: SemanticEventVocabulary.category(for: name) ?? .affect,
            name: name,
            source: .tag(family: family.rawValue),
            payload: payload
        )]
    }

    /// Event name and payload for one of the six event markers with a
    /// well-formed numeric payload; `nil` for anything else.
    private static func routed(marker: String, numbers: [Int]) -> (String, [String: String])? {
        switch (marker, numbers.count) {
        case ("affon", 2):
            ("affect_on", ["spell": "\(numbers[0])", "seconds": "\(numbers[1])"])
        case ("affoff", 1):
            ("affect_off", ["spell": "\(numbers[0])"])
        case ("recon", 2):
            ("recovery_on", ["recovery": "\(numbers[0])", "seconds": "\(numbers[1])"])
        case ("recoff", 1):
            ("recovery_off", ["recovery": "\(numbers[0])"])
        case ("sfail", 4):
            castFailed(numbers).map { ("cast_failed", $0) }
        case ("skillgain", 2):
            ("skill_gain", ["skill": "\(numbers[0])", "percent": "\(numbers[1])"])
        default:
            nil
        }
    }

    /// `{sfail}spell,target,reason,recovery` per `help spelltags`. The target
    /// is documented as 0 (self) or 1 (other) only; the recovery number is
    /// meaningful only when non-negative.
    private static func castFailed(_ numbers: [Int]) -> [String: String]? {
        guard let target = ["self", "other"][safe: numbers[1]] else { return nil }
        var payload = [
            "spell": "\(numbers[0])",
            "target": target,
            "reason": "\(numbers[2])",
            "reasonName": castFailureReasons[numbers[2]] ?? "unknown"
        ]
        if numbers[3] >= 0 { payload["recovery"] = "\(numbers[3])" }
        return payload
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import Foundation

/// One mob in the Consider list: its display name, the resolved targeting
/// `keyword`, the per-name disambiguation `index` (the *N* in `N.keyword`), its
/// difficulty colour/range, captured aura flags, and live combat status. Mirrors
/// the plugin's `targT` entry.
public struct ConsiderMob: Sendable, Equatable, Identifiable {
    public let id: Int
    public var name: String
    public var keyword: String
    /// Where ``keyword`` came from (the player, S&D, or a guess); nil for the
    /// `Stripname` fallback used without a keyword book.
    public var keywordSource: MobKeywordBook.Source?
    /// Set for a mob that can't be attacked (divine protection, a
    /// shopkeeper): listed, never targeted.
    public var unattackable: ConsiderLine.Unattackable?
    /// The duplicate-disambiguation number: among living mobs of the same name,
    /// 1 = first, 2 = second, … Recomputed as mobs die / leave.
    public var index: Int = 1
    public var colour: String = ""
    public var rangeLabel: String = ""
    /// The raw aura-flags text captured before the mob name (`"(Red Aura) "`,
    /// `"(R) "`, …), or empty. The batch filter inspects this for alignment/sanc.
    public var rawFlags: String = ""
    public var dead: Bool = false
    public var attacked: Bool = false
    public var left: Bool = false
    /// The exit a departed mob took; nil when it fled.
    public var leftTo: String?
    public var fled: Bool = false
    public var came: Bool = false
    /// Remaining health percent (kills set 0); drives kill-victim selection order.
    public var pct: Int = 100
    /// Order in which this mob was attacked this round (0 = not yet) — a
    /// tiebreaker when several same-named mobs could be the kill victim.
    public var attackSequence: Int = 0

    /// What the panel shows after the name: where a departed mob went, else
    /// its level range (or why it can't be attacked, or that it arrived).
    public var detail: String {
        guard left else { return rangeLabel }
        if fled { return "fled" }
        return leftTo.map { "left \($0)" } ?? "left"
    }
}

/// What ``ConsiderModel/ingestLine(_:zone:keyword:)`` did with a line — lets the
/// owning feature decide display (gag the considered mob lines) and reactions.
public enum ConsiderLineOutcome: Sendable, Equatable {
    /// Not a line the model cares about (a departure counts only for a mob
    /// on the list).
    case ignored
    /// A `consider all` mob line matched — the feature should gag it. The
    /// tier is nil for an unattackable mob.
    case considered(ConsiderTier?)
    case mobLeft(String)
    case mobArrived(String)
    case mobFled(String)
    case mobKilled(String)
}

/// The pure parser + state machine behind the native Consider feature: it turns
/// `consider all` output and room-movement / kill / flee lines into an ordered,
/// de-duplicated mob list, exactly as the canonical MUSHclient plugin does — but
/// as a value type that *decides* only (no UI, network, or Lua), so it is fully
/// unit-testable. The owning ``NativePlugin`` feeds it lines + GMCP and renders
/// its ``mobs``; see ``ConsiderModel/ingestLine(_:zone:keyword:)``.
///
/// Faithful to `Aardwolf_Consider_Miniwin.lua`: accumulation clears on the first
/// matched line of a run (`waiting_for_consider_start`), indices are recomputed
/// over living same-named mobs (`Update_mobs_indicies`), and kill-victim
/// selection follows the plugin's pct/attacked/sequence ordering.
public struct ConsiderModel: Sendable, Equatable {
    /// The current room's mobs, in `consider all` order (arrivals prepend).
    /// Read-only outside MudCore; mutated only by this model's own transitions.
    public internal(set) var mobs: [ConsiderMob] = []
    /// Zones in which arrivals/departures are ignored (the plugin's
    /// `conw_ignore_areas`). Empty by default.
    public var ignoredZones: Set<String> = []

    /// Whether a `consider all` capture is active (the plugin enables its
    /// "consider" trigger group only during a run).
    public private(set) var considering = false
    private var waitingForStart = false
    private var attackSequenceCounter = 0
    var nextID = 0

    public init() {}

    // MARK: - Consider run lifecycle

    /// Begin a `consider all` capture (the feature calls this when it sends the
    /// command). The accumulated list is not cleared until the first mob line
    /// arrives, so a no-result run can be detected.
    public mutating func beginConsider() {
        considering = true
        waitingForStart = true
    }

    /// End the capture. If no mob line ever matched, the list is cleared (the
    /// plugin's `Consider_end` behaviour for an empty room).
    public mutating func endConsider() {
        if waitingForStart { mobs = [] }
        waitingForStart = false
        considering = false
    }

    /// Empty the list and abandon any capture (used for safe rooms / ignored
    /// zones, where there's nothing to consider).
    public mutating func clear() {
        mobs = []
        waitingForStart = false
        considering = false
    }

    // MARK: - Line ingestion

    /// Feed one incoming line. `zone` (current `room.info.zone`) gates ignored
    /// zones and the name-cleanup citadel case; `keyword` resolves a display name
    /// to a targeting keyword (inject a Search-and-Destroy-backed resolver, or
    /// omit for the ported `Stripname` fallback).
    @discardableResult
    public mutating func ingestLine(
        _ text: String,
        zone: String? = nil,
        keyword: ((String) -> MobKeywordBook.Resolved)? = nil
    ) -> ConsiderLineOutcome {
        if considering, let hit = ConsiderLine.parse(text) {
            if waitingForStart {
                waitingForStart = false
                mobs = []
                attackSequenceCounter = 0
            }
            appendConsidered(hit, keyword: Self.resolve(hit.name, zone: zone, keyword))
            return .considered(hit.tier)
        }
        if !isIgnored(zone) {
            if let departure = ConsiderMovement.departure(text) {
                if handleMobLeft(departure.name, to: departure.exit) { return .mobLeft(departure.name) }
            }
            if let name = ConsiderMovement.arrival(text) {
                handleMobCame(name, zone: zone, keyword: keyword)
                return .mobArrived(name)
            }
            if let name = ConsiderMovement.fled(text) {
                handleMobLeft(name, to: nil)
                return .mobFled(name)
            }
        }
        if let victim = Self.matcher.kill(text) {
            handleKill(victim)
            return .mobKilled(victim)
        }
        return .ignored
    }

    private func isIgnored(_ zone: String?) -> Bool {
        guard let zone else { return false }
        return ignoredZones.contains(zone)
    }

    // MARK: - State transitions (ported from the plugin)

    private mutating func appendConsidered(_ hit: ConsiderLine, keyword: (String, MobKeywordBook.Source?)) {
        var mob = ConsiderMob(id: nextID, name: hit.name, keyword: keyword.0)
        mob.keywordSource = keyword.1
        mob.colour = hit.tier?.colour ?? "gray"
        mob.rangeLabel = hit.tier?.rangeLabel ?? hit.unattackable?.label ?? ""
        mob.rawFlags = hit.rawFlags.trimmingCharacters(in: .whitespaces)
        mob.unattackable = hit.unattackable
        nextID += 1
        mobs.append(mob)
        recomputeIndices()
    }

    /// A name's keyword: the book's when the feature has one, else the
    /// plugin's `Stripname` fallback.
    private static func resolve(
        _ name: String, zone: String?, _ keyword: ((String) -> MobKeywordBook.Resolved)?
    ) -> (String, MobKeywordBook.Source?) {
        guard let resolved = keyword?(name) else { return (ConsiderNameCleanup.strip(name, zone: zone), nil) }
        return (resolved.keyword, resolved.source)
    }

    /// `Update_mob_came`: a mob arrived — prepend it, its difficulty not yet
    /// considered (the plugin's `???`).
    private mutating func handleMobCame(
        _ name: String, zone: String?, keyword: ((String) -> MobKeywordBook.Resolved)?
    ) {
        let resolved = Self.resolve(name, zone: zone, keyword)
        var mob = ConsiderMob(id: nextID, name: name, keyword: resolved.0)
        mob.keywordSource = resolved.1
        mob.colour = "gray"
        mob.rangeLabel = "arrived"
        mob.came = true
        nextID += 1
        mobs.insert(mob, at: 0)
        recomputeIndices()
    }

    /// `Update_mob_left`: a mob left by `exit`, or fled (nil). Prefer
    /// cancelling a matching recent arrival, else mark the first living
    /// un-attacked match, else any living match, as left. Returns whether a
    /// mob on the list matched.
    @discardableResult
    private mutating func handleMobLeft(_ name: String, to exit: String?) -> Bool {
        let key = Self.lowerFirst(name)
        let named = { (mob: ConsiderMob) in Self.lowerFirst(mob.name) == key }
        if let i = mobs.firstIndex(where: { named($0) && $0.came && !$0.left && !$0.dead }) {
            mobs.remove(at: i)
            recomputeIndices()
            return true
        }
        let index = mobs.lastIndex { !$0.attacked && !$0.dead && !$0.left && named($0) }
            ?? mobs.lastIndex { !$0.dead && !$0.left && named($0) }
        guard let index else { return false }
        mobs[index].left = true
        mobs[index].leftTo = exit
        mobs[index].fled = exit == nil
        recomputeIndices()
        return true
    }

    /// `Update_kill`: mark the most-likely victim dead. The plugin matches a
    /// death message that *starts with* a mob's name (first letter lowercased to
    /// match "project force"-style messages), choosing among duplicates by the
    /// pct → attacked → sequence ordering.
    private mutating func handleKill(_ victim: String) {
        let victimKey = Self.lowerFirst(victim)
        let order = killSelectionOrder()
        for i in order where !mobs[i].dead {
            let mobKey = Self.lowerFirst(mobs[i].name)
            if !mobKey.isEmpty, victimKey.hasPrefix(mobKey) {
                mobs[i].dead = true
                mobs[i].rawFlags = ""
                mobs[i].pct = 0
                recomputeIndices()
                return
            }
        }
    }

    /// Indices into ``mobs`` ordered the way the plugin's `spairs(targT,
    /// FinbMobTargetSortFunction)` walks them: lowest pct first, then attacked
    /// before un-attacked, then earliest attack, then list order.
    private func killSelectionOrder() -> [Int] {
        mobs.indices.sorted { lhs, rhs in
            let left = mobs[lhs], right = mobs[rhs]
            if left.pct != right.pct { return left.pct < right.pct }
            if left.attacked != right.attacked { return left.attacked && !right.attacked }
            if left.attackSequence != right
                .attackSequence { return left.attackSequence < right.attackSequence }
            return lhs < rhs
        }
    }

    /// `Update_mobs_indicies`: renumber each mob as 1 + the count of *living*
    /// (not dead, not left) earlier mobs sharing its name. Recomputed wholesale
    /// — the lists are small and this keeps the invariant simple.
    mutating func recomputeIndices() {
        for i in mobs.indices {
            var count = 1
            for j in 0..<i where mobs[j].name == mobs[i].name && !(mobs[j].dead || mobs[j].left) {
                count += 1
            }
            mobs[i].index = count
        }
    }

    private static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: - Single-target attack

    /// Mark the 1-based list position `position` attacked and return the command
    /// to send for it, formatted for `mode`. Returns nil if out of range
    /// (the plugin's `Command_line` guard).
    public mutating func attackCommand(
        position: Int, command: String, mode: ConsiderExecuteMode
    ) -> String? {
        guard position >= 1, position <= mobs.count,
              mobs[position - 1].unattackable == nil else { return nil }
        let i = position - 1
        mobs[i].attacked = true
        attackSequenceCounter += 1
        mobs[i].attackSequence = attackSequenceCounter
        return "\(command) \(target(for: mobs[i], mode: mode))"
    }

    /// Format a mob's target argument per execute mode (`Execute_Mob`):
    /// `pro` → `N keyword`, `cast` → `'N.keyword'`, default → `N.'keyword'`.
    public func target(for mob: ConsiderMob, mode: ConsiderExecuteMode) -> String {
        switch mode {
        case .pro: "\(mob.index) \(mob.keyword)"
        case .cast: "'\(mob.index).\(mob.keyword)'"
        case .skill: "\(mob.index).'\(mob.keyword)'"
        }
    }

    // MARK: - Matcher

    /// Precompiled matchers for the kill patterns, reusing the shared
    /// ``PatternMatcher`` (the tiers are ``ConsiderLine``'s; movement is
    /// ``ConsiderMovement``'s). The literals are known-good (from the plugin),
    /// so compilation can't fail in practice.
    struct Matcher {
        let kills: [PatternMatcher]

        // swiftlint:disable force_try
        init() {
            kills = ConsiderLinePatterns.kills
                .map { try! PatternMatcher(pattern: .regex($0), caseSensitive: true) }
        }

        // swiftlint:enable force_try

        func kill(_ line: String) -> String? {
            for pattern in kills {
                if let name = capture1(pattern, line) { return name }
            }
            return nil
        }

        private func capture1(_ matcher: PatternMatcher, _ line: String) -> String? {
            guard let result = matcher.match(line), result.captures.count > 1,
                  !result.captures[1].isEmpty else { return nil }
            return result.captures[1]
        }
    }

    static let matcher = Matcher()
}

/// How the attack command targets a mob (the plugin's `conw_execute_mode`):
/// a skill/command (`kill N.'keyword'`), a spell (`cast 'N.keyword'`), or a
/// "protect"-style numbered target (`N keyword`).
public enum ConsiderExecuteMode: String, Sendable, Equatable, CaseIterable, Codable {
    case skill
    case cast
    case pro
}

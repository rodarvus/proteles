import Foundation

/// One mob in the Consider list: its display name, the resolved targeting
/// `keyword`, the per-name disambiguation `index` (the *N* in `N.keyword`), its
/// difficulty colour/range, captured aura flags, and live combat status. Mirrors
/// the plugin's `targT` entry.
public struct ConsiderMob: Sendable, Equatable, Identifiable {
    public let id: Int
    public var name: String
    public var keyword: String
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
    public var came: Bool = false
    /// Remaining health percent (kills set 0); drives kill-victim selection order.
    public var pct: Int = 100
    /// Order in which this mob was attacked this round (0 = not yet) — a
    /// tiebreaker when several same-named mobs could be the kill victim.
    public var attackSequence: Int = 0
}

/// What ``ConsiderModel/ingestLine(_:zone:keyword:)`` did with a line — lets the
/// owning feature decide display (gag the considered mob lines) and reactions.
public enum ConsiderLineOutcome: Sendable, Equatable {
    /// Not a line the model cares about.
    case ignored
    /// A `consider all` mob line matched this tier — the feature should gag it.
    case considered(ConsiderTier)
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
    private var nextID = 0

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

    // MARK: - Line ingestion

    /// Feed one incoming line. `zone` (current `room.info.zone`) gates ignored
    /// zones and the name-cleanup citadel case; `keyword` resolves a display name
    /// to a targeting keyword (inject a Search-and-Destroy-backed resolver, or
    /// omit for the ported `Stripname` fallback).
    @discardableResult
    public mutating func ingestLine(
        _ text: String,
        zone: String? = nil,
        keyword: ((String) -> String)? = nil
    ) -> ConsiderLineOutcome {
        if considering, let hit = Self.matcher.tier(for: text) {
            if waitingForStart {
                waitingForStart = false
                mobs = []
                attackSequenceCounter = 0
            }
            let kw = keyword?(hit.name) ?? ConsiderNameCleanup.strip(hit.name, zone: zone)
            appendConsidered(name: hit.name, keyword: kw, flags: hit.flags, tier: hit.tier)
            return .considered(hit.tier)
        }
        if let name = Self.matcher.mobLeft(text) {
            if !isIgnored(zone) { handleMobLeft(name) }
            return .mobLeft(name)
        }
        if let name = Self.matcher.mobArrived(text) {
            if !isIgnored(zone) { handleMobCame(name, zone: zone, keyword: keyword) }
            return .mobArrived(name)
        }
        if let name = Self.matcher.mobFled(text) {
            if !isIgnored(zone) { handleMobLeft(name) }
            return .mobFled(name)
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

    private mutating func appendConsidered(name: String, keyword: String, flags: String, tier: ConsiderTier) {
        var mob = ConsiderMob(id: nextID, name: name, keyword: keyword)
        mob.colour = tier.colour
        mob.rangeLabel = tier.rangeLabel
        mob.rawFlags = flags
        nextID += 1
        mobs.append(mob)
        recomputeIndices()
    }

    /// `Update_mob_came`: a mob arrived — prepend it with unknown difficulty.
    private mutating func handleMobCame(_ name: String, zone: String?, keyword: ((String) -> String)?) {
        let kw = keyword?(name) ?? ConsiderNameCleanup.strip(name, zone: zone)
        var mob = ConsiderMob(id: nextID, name: name, keyword: kw)
        mob.colour = "gray"
        mob.rangeLabel = "???"
        mob.came = true
        nextID += 1
        mobs.insert(mob, at: 0)
        recomputeIndices()
    }

    /// `Update_mob_left`: a mob left / fled. Prefer cancelling a matching recent
    /// arrival, else mark the first living un-attacked match, else any living
    /// match, as left.
    private mutating func handleMobLeft(_ name: String) {
        if let i = mobs.firstIndex(where: { $0.name == name && $0.came && !$0.left && !$0.dead }) {
            mobs.remove(at: i)
            recomputeIndices()
            return
        }
        if let i = mobs.lastIndex(where: { !$0.attacked && !$0.dead && !$0.left && $0.name == name }) {
            mobs[i].left = true
            recomputeIndices()
            return
        }
        if let i = mobs.lastIndex(where: { !$0.dead && !$0.left && $0.name == name }) {
            mobs[i].left = true
            recomputeIndices()
        }
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
    private mutating func recomputeIndices() {
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
        guard position >= 1, position <= mobs.count else { return nil }
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

    /// Precompiled matchers for the tiers and movement/kill patterns, reusing the
    /// shared ``PatternMatcher``. The literals are known-good (from the plugin),
    /// so compilation can't fail in practice.
    struct Matcher {
        let tiers: [(tier: ConsiderTier, matcher: PatternMatcher)]
        let left: PatternMatcher
        let arrived: [PatternMatcher]
        let fled: PatternMatcher
        let kills: [PatternMatcher]

        // swiftlint:disable force_try
        init() {
            tiers = ConsiderTier.all.map {
                ($0, try! PatternMatcher(pattern: .regex($0.pattern), caseSensitive: true))
            }
            left = try! PatternMatcher(pattern: .regex(ConsiderLinePatterns.mobLeft), caseSensitive: true)
            arrived = [ConsiderLinePatterns.mobArrivedFrom, ConsiderLinePatterns.mobAppeared]
                .map { try! PatternMatcher(pattern: .regex($0), caseSensitive: true) }
            fled = try! PatternMatcher(pattern: .regex(ConsiderLinePatterns.mobFled), caseSensitive: true)
            kills = ConsiderLinePatterns.kills
                .map { try! PatternMatcher(pattern: .regex($0), caseSensitive: true) }
        }

        // swiftlint:enable force_try

        /// A consider tier match: its tier, the mob name (capture 2), and the
        /// trimmed aura flags (capture 1).
        struct TierHit {
            let tier: ConsiderTier
            let name: String
            let flags: String
        }

        func tier(for line: String) -> TierHit? {
            for entry in tiers {
                guard let result = entry.matcher.match(line), result.captures.count > 2 else { continue }
                let name = result.captures[2]
                guard !name.isEmpty else { continue }
                let flags = result.captures[1].trimmingCharacters(in: .whitespaces)
                return TierHit(tier: entry.tier, name: name, flags: flags)
            }
            return nil
        }

        func mobLeft(_ line: String) -> String? {
            capture1(left, line)
        }

        func mobFled(_ line: String) -> String? {
            capture1(fled, line)
        }

        func mobArrived(_ line: String) -> String? {
            for pattern in arrived {
                if let name = capture1(pattern, line) { return name }
            }
            return nil
        }

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

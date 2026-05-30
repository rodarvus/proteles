import Foundation

// Value-type result models for the **leveldb** native reporting panels
// (PLAN.md D-71). These are derived *read-only* from the leveldb plugin's own
// SQLite file (`leveldb.db`) — the plugin remains the single writer; Proteles
// only reads, exactly as the mapper reads its DB. Keeping the shapes here (pure
// `Sendable` structs) lets ``LevelDBStore``'s queries be unit-tested without UI.

/// A tier/remort progression band. `nil` fields mean "all" (no filter); a fully
/// specified band identifies one remort of one tier (Aardwolf's progression
/// unit). Kills/deaths/quests are all stamped with the band that was active.
public struct LevelDBBand: Sendable, Hashable, Codable, Identifiable {
    public var tier: Int?
    public var remort: Int?

    public init(tier: Int? = nil, remort: Int? = nil) {
        self.tier = tier
        self.remort = remort
    }

    /// The "no filter" band (all tiers, all remorts).
    public static let all = LevelDBBand()

    public var id: String {
        "\(tier.map(String.init) ?? "*")/\(remort.map(String.init) ?? "*")"
    }

    /// `true` when neither tier nor remort is constrained.
    public var isAll: Bool {
        tier == nil && remort == nil
    }

    /// Human label, e.g. "Tier 4 · Remort 5", "Tier 3 · all remorts", "All".
    public var label: String {
        switch (tier, remort) {
        case (nil, nil): "All progression"
        case (.some(let tier), nil): "Tier \(tier)"
        case (nil, .some(let remort)): "Remort \(remort)"
        case (.some(let tier), .some(let remort)): "Tier \(tier) · Remort \(remort)"
        }
    }

    public var shortLabel: String {
        switch (tier, remort) {
        case (nil, nil): "All"
        case (.some(let tier), nil): "T\(tier)"
        case (nil, .some(let remort)): "R\(remort)"
        case (.some(let tier), .some(let remort)): "T\(tier) R\(remort)"
        }
    }
}

/// Headline totals across the whole database, plus the character's current
/// standing (the most recent kill's level/tier/remort) and the single best XP
/// day. Drives the panel footer and the journey/live headers.
public struct LevelDBSummary: Sendable, Equatable, Codable {
    public var totalKills = 0
    public var totalXP = 0
    public var totalGold = 0
    public var totalDeaths = 0
    public var totalQuests = 0
    public var totalCampaigns = 0
    public var currentLevel = 0
    public var currentTier: Int?
    public var currentRemort: Int?
    public var bestDay: LevelDBDaily?

    public init() {}

    public var currentBand: LevelDBBand {
        LevelDBBand(tier: currentTier, remort: currentRemort)
    }
}

/// Per-zone efficiency, the core "where should I grind?" report.
public struct LevelDBZoneStat: Sendable, Equatable, Codable, Identifiable {
    public var zone: String
    public var kills: Int
    public var xp: Int
    public var gold: Int
    /// Total seconds of combat recorded for these kills (0 when unknown).
    public var combatSeconds: Double
    public var id: String {
        zone
    }

    public init(zone: String, kills: Int, xp: Int, gold: Int, combatSeconds: Double) {
        self.zone = zone
        self.kills = kills
        self.xp = xp
        self.gold = gold
        self.combatSeconds = combatSeconds
    }

    /// XP per second of combat (0 when no combat time is recorded). The headline
    /// efficiency metric leveldb's own zone report ranks by.
    public var xpPerSecond: Double {
        combatSeconds > 0 ? Double(xp) / combatSeconds : 0
    }

    public var averageXP: Double {
        kills > 0 ? Double(xp) / Double(kills) : 0
    }
}

/// Per-mob kill tally (the "top mobs" report).
public struct LevelDBMobStat: Sendable, Equatable, Codable, Identifiable {
    public var mob: String
    public var zone: String
    public var kills: Int
    public var xp: Int
    public var id: String {
        "\(mob)@\(zone)"
    }

    public init(mob: String, zone: String, kills: Int, xp: Int) {
        self.mob = mob
        self.zone = zone
        self.kills = kills
        self.xp = xp
    }
}

/// Aggregate quest / campaign / global-quest outcomes for a band.
public struct LevelDBObjectiveStat: Sendable, Equatable, Codable {
    public var attempts = 0
    public var succeeded = 0
    public var totalQP = 0
    public var totalGold = 0
    public var totalTrains = 0
    public var totalPracs = 0
    /// Total duration in seconds across all rows (for the average).
    public var totalDuration = 0

    public init() {}

    public var averageQP: Double {
        attempts > 0 ? Double(totalQP) / Double(attempts) : 0
    }

    public var averageDurationSeconds: Double {
        attempts > 0 ? Double(totalDuration) / Double(attempts) : 0
    }

    public var successRate: Double {
        attempts > 0 ? Double(succeeded) / Double(attempts) : 0
    }
}

/// One day's totals (for the daily report, the analytics line chart, and the
/// journey heatmap).
public struct LevelDBDaily: Sendable, Equatable, Codable, Identifiable {
    /// `YYYY-MM-DD` in the local timezone (leveldb stamps unix timestamps).
    public var day: String
    public var kills: Int
    public var xp: Int
    public var id: String {
        day
    }

    public init(day: String, kills: Int, xp: Int) {
        self.day = day
        self.kills = kills
        self.xp = xp
    }
}

/// A single level-up event, for the analytics level curve.
public struct LevelDBLevelPoint: Sendable, Equatable, Codable, Identifiable {
    public var timestamp: Date
    public var level: Int
    public var tier: Int?
    public var remort: Int?
    public var id: Double {
        timestamp.timeIntervalSince1970
    }

    public init(timestamp: Date, level: Int, tier: Int?, remort: Int?) {
        self.timestamp = timestamp
        self.level = level
        self.tier = tier
        self.remort = remort
    }
}

/// Where the character's gold came from (the `events` table, category `gold`).
public struct LevelDBGoldSource: Sendable, Equatable, Codable, Identifiable {
    public var source: String
    public var amount: Int
    public var id: String {
        source
    }

    public init(source: String, amount: Int) {
        self.source = source
        self.amount = amount
    }
}

/// One death (the deaths report — rare enough to list individually).
public struct LevelDBDeath: Sendable, Equatable, Codable, Identifiable {
    public var timestamp: Date
    public var mob: String
    public var zone: String
    public var level: Int
    public var id: Double {
        timestamp.timeIntervalSince1970
    }

    public init(timestamp: Date, mob: String, zone: String, level: Int) {
        self.timestamp = timestamp
        self.mob = mob
        self.zone = zone
        self.level = level
    }
}

/// A completed (or in-progress) progression chapter for the journey view: one
/// band, with its span, kills, deaths, and best zone.
public struct LevelDBChapter: Sendable, Equatable, Codable, Identifiable {
    public var band: LevelDBBand
    public var kills: Int
    public var deaths: Int
    public var minLevel: Int
    public var maxLevel: Int
    public var bestZone: String?
    public var firstSeen: Date?
    public var lastSeen: Date?
    public var id: String {
        band.id
    }

    public init(
        band: LevelDBBand,
        kills: Int,
        deaths: Int,
        minLevel: Int,
        maxLevel: Int,
        bestZone: String?,
        firstSeen: Date?,
        lastSeen: Date?
    ) {
        self.band = band
        self.kills = kills
        self.deaths = deaths
        self.minLevel = minLevel
        self.maxLevel = maxLevel
        self.bestZone = bestZone
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Real-time-ish efficiency for the live HUD, derived from recent rows (no
/// coupling to the running plugin — "today" + "last hour" off the DB).
public struct LevelDBLiveStats: Sendable, Equatable, Codable {
    public var todayKills = 0
    public var todayXP = 0
    public var todayGold = 0
    /// XP earned in the last 60 minutes (the live XP/hour estimate).
    public var lastHourXP = 0
    public var lastHourKills = 0
    /// Mean combat seconds across the last hour's kills (0 when none).
    public var recentCombatSeconds = 0.0
    /// The current band's best zone by XP/sec (for "this zone vs your best").
    public var bestZone: LevelDBZoneStat?
    /// Mean XP needed per level in the current band (for the "next level" ETA).
    public var xpPerLevelEstimate = 0.0

    public init() {}

    /// Projected XP/hour from the last hour's earning (already an hourly figure).
    public var xpPerHour: Int {
        lastHourXP
    }

    public var killsPerMinute: Double {
        lastHourKills > 0 ? Double(lastHourKills) / 60.0 : 0
    }

    /// Estimated minutes to the next level at the last hour's pace, or `nil`
    /// when we can't estimate (no recent XP or no per-level baseline).
    public var minutesToNextLevel: Double? {
        guard lastHourXP > 0, xpPerLevelEstimate > 0 else { return nil }
        return xpPerLevelEstimate / (Double(lastHourXP) / 60.0)
    }
}

/// The complete report bundle the panel renders, loaded together for one band
/// selection so the view never queries the DB directly.
public struct LevelDBReport: Sendable, Equatable, Codable {
    public var summary = LevelDBSummary()
    public var band = LevelDBBand.all
    public var zones: [LevelDBZoneStat] = []
    public var mobs: [LevelDBMobStat] = []
    public var quests = LevelDBObjectiveStat()
    public var campaigns = LevelDBObjectiveStat()
    public var globalQuests = LevelDBObjectiveStat()
    public var deaths: [LevelDBDeath] = []
    public var daily: [LevelDBDaily] = []
    public var levelCurve: [LevelDBLevelPoint] = []
    public var goldSources: [LevelDBGoldSource] = []
    public var chapters: [LevelDBChapter] = []
    public var live = LevelDBLiveStats()
    public var bands: [LevelDBBand] = []

    public init() {}
}

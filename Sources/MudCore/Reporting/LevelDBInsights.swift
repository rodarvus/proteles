import Foundation

// The Levels window's insight models (#12 redesign): the rich day story,
// pace + projection, activity economics, and records — all derived
// read-only from the leveldb plugin's SQLite (the plugin stays the sole
// writer, D-71). Pure values; the queries live in `LevelDBStore+Insights`.

/// One day's headline numbers — the Days list + calendar heatmap intensity.
public struct LevelDBDaySummary: Sendable, Equatable, Codable, Identifiable {
    /// `YYYY-MM-DD`, local timezone.
    public var day: String
    public var xp: Int
    public var kills: Int
    public var levels: Int
    public var pups: Int
    public var campaignsDone: Int
    public var questsDone: Int
    public var gquests: Int
    public var deaths: Int
    public var qpEarned: Int
    public var goldEarned: Int
    /// Estimated seconds actually played: kill-to-kill gaps ≤ 10 min summed.
    public var activeSeconds: Int

    public var id: String {
        day
    }

    public init(
        day: String,
        xp: Int = 0,
        kills: Int = 0,
        levels: Int = 0,
        pups: Int = 0,
        campaignsDone: Int = 0,
        questsDone: Int = 0,
        gquests: Int = 0,
        deaths: Int = 0,
        qpEarned: Int = 0,
        goldEarned: Int = 0,
        activeSeconds: Int = 0
    ) {
        self.day = day
        self.xp = xp
        self.kills = kills
        self.levels = levels
        self.pups = pups
        self.campaignsDone = campaignsDone
        self.questsDone = questsDone
        self.gquests = gquests
        self.deaths = deaths
        self.qpEarned = qpEarned
        self.goldEarned = goldEarned
        self.activeSeconds = activeSeconds
    }
}

/// One notable moment in a day's chronological story.
public struct LevelDBDayEvent: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case level, pup, campaign, quest, gquest, death
    }

    public var timestamp: Date
    public var kind: Kind
    /// Headline ("Level 173", "Pup #61 in Ascent", "Campaign — 8 mobs").
    public var title: String
    /// Reward/result summary ("+18 qp · 6,500 gold · 1 tp", "failed").
    public var detail: String
    /// Failed/death events render in the warning tint.
    public var isNegative: Bool

    public var id: String {
        "\(timestamp.timeIntervalSince1970)-\(kind.rawValue)-\(title)"
    }

    public init(timestamp: Date, kind: Kind, title: String, detail: String, isNegative: Bool = false) {
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isNegative = isNegative
    }
}

/// XP landed per local hour (0–23) — the day's activity strip and the
/// "best playing hours" chart.
public struct LevelDBHourBucket: Sendable, Equatable, Codable, Identifiable {
    public var hour: Int
    public var xp: Int
    public var kills: Int

    public var id: Int {
        hour
    }

    public init(hour: Int, xp: Int, kills: Int) {
        self.hour = hour
        self.xp = xp
        self.kills = kills
    }
}

/// Everything the Days tab shows for one selected day.
public struct LevelDBDayDetail: Sendable, Equatable, Codable {
    public var summary: LevelDBDaySummary
    public var events: [LevelDBDayEvent] = []
    public var hourly: [LevelDBHourBucket] = []

    public init(summary: LevelDBDaySummary) {
        self.summary = summary
    }
}

/// Pace + projection: how fast levels/pups come, and where that leads.
public struct LevelDBPace: Sendable, Equatable, Codable {
    /// Median seconds per level in the current band (outlier-resistant).
    public var medianLevelSeconds: Double?
    /// Median over the last 10 levels (the *current* pace).
    public var recentLevelSeconds: Double?
    /// XP per active hour, last 7 days / last 30 days.
    public var xpPerHour7d: Double?
    public var xpPerHour30d: Double?
    /// Average active seconds per day, last 7 days with any play.
    public var activeSecondsPerDay7d: Double?
    /// Pups per active hour in the current band (T9+/redo play).
    public var pupsPerHour: Double?
    /// XP by local hour across the last 30 days (best playing hours).
    public var hourly: [LevelDBHourBucket] = []
    /// Current level + the band's ceiling (201 = remort), for the projection.
    public var currentLevel: Int?
    /// "At your recent pace + daily playtime: ~N days to remort." Nil when
    /// there's no recent pace to project from (or already at the ceiling).
    public var daysToRemort: Double?

    public init() {}
}

/// What an activity actually pays — one row per campaign/quest/gquest.
public struct LevelDBActivityEconomics: Sendable, Equatable, Codable, Identifiable {
    public var activity: String
    public var count: Int
    /// 0–1 over rows with a known result.
    public var successRate: Double?
    public var avgDurationSeconds: Double?
    public var avgQP: Double?
    public var avgGold: Double?
    public var avgTP: Double?
    /// QP per minute of the activity itself (its real hourly wage).
    public var qpPerMinute: Double?

    public var id: String {
        activity
    }

    public init(activity: String, count: Int) {
        self.activity = activity
        self.count = count
    }
}

/// Personal bests + lifetime totals.
public struct LevelDBRecords: Sendable, Equatable, Codable {
    public struct Best: Sendable, Equatable, Codable {
        public var label: String
        public var value: String
        public var when: String

        public init(label: String, value: String, when: String) {
            self.label = label
            self.value = value
            self.when = when
        }
    }

    public struct RemortRow: Sendable, Equatable, Codable, Identifiable {
        public var tier: Int
        public var remort: Int
        public var levels: Int
        public var medianLevelSeconds: Double?

        public var id: String {
            "t\(tier)r\(remort)"
        }

        public init(tier: Int, remort: Int, levels: Int, medianLevelSeconds: Double?) {
            self.tier = tier
            self.remort = remort
            self.levels = levels
            self.medianLevelSeconds = medianLevelSeconds
        }
    }

    public var bests: [Best] = []
    /// Lifetime totals as (label, formatted value) pairs, render-ready.
    public var lifetime: [Best] = []
    /// Average leveling speed per remort — the cross-remort comparison.
    public var remorts: [RemortRow] = []
    /// Consecutive-days-played streak: current + longest.
    public var currentStreak = 0
    public var longestStreak = 0

    public init() {}
}

/// The full insights bundle the panel loads alongside the classic report.
public struct LevelDBInsightsBundle: Sendable, Equatable, Codable {
    public var days: [LevelDBDaySummary] = []
    public var pace = LevelDBPace()
    public var economics: [LevelDBActivityEconomics] = []
    public var records = LevelDBRecords()

    public init() {}
}

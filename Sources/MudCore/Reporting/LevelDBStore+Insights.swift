import Foundation
import GRDB

/// The #12 insight queries: day summaries/stories, pace + projection,
/// activity economics, records. Read-only, off-main (the panel calls through
/// `load`-style entry points); each query is static for direct testing.
public extension LevelDBStore {
    /// Idle cutoff for the active-time estimate: kill-to-kill gaps longer
    /// than this don't count as play.
    static let idleCutoffSeconds = 600

    /// Aardwolf remorts at level 201 (the superhero+1 boundary) — the pace
    /// projection's ceiling.
    static let remortCeiling = 201

    /// The full insights bundle (one read transaction).
    func insights(now: Date = Date()) throws -> LevelDBInsightsBundle {
        do {
            return try dbQueue.read { db in
                var bundle = LevelDBInsightsBundle()
                bundle.days = try Self.daySummaries(db)
                bundle.pace = try Self.pace(db, now: now)
                bundle.economics = try Self.economics(db)
                bundle.records = try Self.records(db, days: bundle.days, now: now)
                return bundle
            }
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    /// One selected day's full story (timeline + hourly strip).
    func dayDetail(_ day: String) throws -> LevelDBDayDetail {
        do {
            return try dbQueue.read { db in
                let summaries = try Self.daySummaries(db, only: day)
                var detail = LevelDBDayDetail(
                    summary: summaries.first ?? LevelDBDaySummary(day: day)
                )
                detail.events = try Self.dayEvents(db, day: day)
                detail.hourly = try Self.hourlyXP(db, day: day)
                return detail
            }
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    // MARK: - Days

    /// Per-day headline numbers, newest first. `only` narrows to one day.
    static func daySummaries(_ db: Database, only day: String? = nil) throws -> [LevelDBDaySummary] {
        let dayFilter = day.map { _ in "WHERE day = ?" } ?? ""
        let args: [DatabaseValueConvertible] = day.map { [$0] } ?? []
        // One pass per source table, joined on the local-time day string.
        // LAG() computes the kill-to-kill gap for the active-time estimate.
        let sql = Self.daySummariesSQL(dayFilter: dayFilter)
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.compactMap { row in
            guard let day: String = row["day"] else { return nil }
            return LevelDBDaySummary(
                day: day,
                xp: row["xp"] ?? 0,
                kills: row["kills"] ?? 0,
                levels: row["levels"] ?? 0,
                pups: row["pups"] ?? 0,
                campaignsDone: row["cps"] ?? 0,
                questsDone: row["quests"] ?? 0,
                gquests: row["gqs"] ?? 0,
                deaths: row["deaths"] ?? 0,
                qpEarned: row["qp"] ?? 0,
                goldEarned: row["gold"] ?? 0,
                activeSeconds: row["active"] ?? 0
            )
        }
    }

    /// The day-summary SQL (hoisted so the query function stays within the
    /// body-length budget; the literal dominates it).
    private static func daySummariesSQL(dayFilter: String) -> String {
        """
        WITH k AS (
          SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
                 count(*) AS kills, COALESCE(sum(xp_gained), 0) AS xp,
                 COALESCE(sum(min(gap, \(idleCutoffSeconds))), 0) AS active
          FROM (
            SELECT timestamp, xp_gained,
                   timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS gap
            FROM kills
          ) GROUP BY day
        ),
        l AS (SELECT date(timestamp, 'unixepoch', 'localtime') AS day, count(*) AS n
              FROM level_events GROUP BY day),
        p AS (SELECT date(timestamp, 'unixepoch', 'localtime') AS day, count(*) AS n
              FROM pup_events GROUP BY day),
        c AS (SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
                     sum(CASE WHEN result = 'completed' THEN 1 ELSE 0 END) AS done,
                     COALESCE(sum(qp), 0) AS qp, COALESCE(sum(gold), 0) AS gold
              FROM campaigns GROUP BY day),
        q AS (SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
                     sum(CASE WHEN result = 'completed' THEN 1 ELSE 0 END) AS done,
                     COALESCE(sum(qp), 0) AS qp, COALESCE(sum(gold), 0) AS gold
              FROM quests GROUP BY day),
        g AS (SELECT date(timestamp, 'unixepoch', 'localtime') AS day, count(*) AS n,
                     COALESCE(sum(qp), 0) AS qp, COALESCE(sum(gold), 0) AS gold
              FROM gquests GROUP BY day),
        d AS (SELECT date(timestamp, 'unixepoch', 'localtime') AS day, count(*) AS n
              FROM deaths GROUP BY day),
        days AS (
          SELECT day FROM k UNION SELECT day FROM l UNION SELECT day FROM p
          UNION SELECT day FROM c UNION SELECT day FROM q
          UNION SELECT day FROM g UNION SELECT day FROM d
        )
        SELECT days.day, COALESCE(k.kills, 0) AS kills, COALESCE(k.xp, 0) AS xp,
               COALESCE(k.active, 0) AS active,
               COALESCE(l.n, 0) AS levels, COALESCE(p.n, 0) AS pups,
               COALESCE(c.done, 0) AS cps, COALESCE(q.done, 0) AS quests,
               COALESCE(g.n, 0) AS gqs, COALESCE(d.n, 0) AS deaths,
               COALESCE(c.qp, 0) + COALESCE(q.qp, 0) + COALESCE(g.qp, 0) AS qp,
               COALESCE(c.gold, 0) + COALESCE(q.gold, 0) + COALESCE(g.gold, 0) AS gold
        FROM days
        LEFT JOIN k ON k.day = days.day
        LEFT JOIN l ON l.day = days.day LEFT JOIN p ON p.day = days.day
        LEFT JOIN c ON c.day = days.day LEFT JOIN q ON q.day = days.day
        LEFT JOIN g ON g.day = days.day LEFT JOIN d ON d.day = days.day
        \(dayFilter.replacingOccurrences(of: "day", with: "days.day"))
        ORDER BY days.day DESC
        """
    }

    /// The day's chronological story: levels, pups, campaign/quest/gquest
    /// results, deaths — merged and time-sorted.
    static func dayEvents(_ db: Database, day: String) throws -> [LevelDBDayEvent] {
        var events: [LevelDBDayEvent] = try progressEvents(db, day: day)
        try events.append(contentsOf: outcomeEvents(db, day: day))
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// One day's rows from `table`, time-filtered.
    private static func dayRows(_ db: Database, _ sql: String, day: String) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: sql + " AND date(timestamp, 'unixepoch', 'localtime') = ?",
            arguments: [day]
        )
    }

    /// Levels + pups (the progress half of the story).
    private static func progressEvents(_ db: Database, day: String) throws -> [LevelDBDayEvent] {
        var events: [LevelDBDayEvent] = []
        func dayRows(_ sql: String) throws -> [Row] {
            try Self.dayRows(db, sql, day: day)
        }

        for row in try dayRows("SELECT timestamp, level FROM level_events WHERE 1=1") {
            events.append(LevelDBDayEvent(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                kind: .level,
                title: "Level \(row["level"] ?? 0)",
                detail: ""
            ))
        }
        for row in try dayRows("SELECT timestamp, pup_number, zone FROM pup_events WHERE 1=1") {
            let zone: String? = row["zone"]
            events.append(LevelDBDayEvent(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                kind: .pup,
                title: "Pup #\(row["pup_number"] ?? 0)",
                detail: zone.map { "in \($0)" } ?? ""
            ))
        }
        return events
    }

    /// Campaign/quest/GQ results + deaths (the outcomes half).
    private static func outcomeEvents(_ db: Database, day: String) throws -> [LevelDBDayEvent] {
        var events: [LevelDBDayEvent] = []
        func dayRows(_ sql: String) throws -> [Row] {
            try Self.dayRows(db, sql, day: day)
        }
        for row in try dayRows(
            "SELECT timestamp, result, mob_count, qp, gold, tp FROM campaigns WHERE 1=1"
        ) {
            let done = (row["result"] as String?) == "completed"
            events.append(LevelDBDayEvent(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                kind: .campaign,
                title: done ? "Campaign — \(row["mob_count"] ?? 0) mobs" : "Campaign failed",
                detail: done ? Self.rewards(row) : "",
                isNegative: !done
            ))
        }
        for row in try dayRows(
            "SELECT timestamp, result, mob_name, area, qp, gold, tp FROM quests WHERE 1=1"
        ) {
            let done = (row["result"] as String?) == "completed"
            let mob: String? = row["mob_name"]
            events.append(LevelDBDayEvent(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                kind: .quest,
                title: done ? "Quest — \(mob ?? "?")" : "Quest failed",
                detail: done ? Self.rewards(row) : "",
                isNegative: !done
            ))
        }
        for row in try dayRows("SELECT timestamp, result, gq_number, qp, gold, tp FROM gquests WHERE 1=1") {
            let result: String? = row["result"]
            let won = result == "won" || result == "completed"
            events.append(LevelDBDayEvent(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                kind: .gquest,
                title: "GQ #\(row["gq_number"] ?? 0) — \(result ?? "?")",
                detail: Self.rewards(row),
                isNegative: !won
            ))
        }
        for row in try dayRows("SELECT timestamp, mob_name, zone FROM deaths WHERE 1=1") {
            let mob: String? = row["mob_name"]
            let zone: String? = row["zone"]
            events.append(LevelDBDayEvent(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                kind: .death,
                title: "Died",
                detail: [mob.map { "to \($0)" }, zone.map { "in \($0)" }]
                    .compactMap(\.self).joined(separator: " "),
                isNegative: true
            ))
        }
        return events
    }

    /// "+18 qp · 6.5k gold · 1 tp" from a row's reward columns.
    private static func rewards(_ row: Row) -> String {
        var parts: [String] = []
        let qp: Int = row["qp"] ?? 0
        let gold: Int = row["gold"] ?? 0
        let tp: Int = row["tp"] ?? 0
        if qp > 0 { parts.append("+\(qp) qp") }
        if gold > 0 { parts.append("\(LevelDBFormatCompact.compact(gold)) gold") }
        if tp > 0 { parts.append("\(tp) tp") }
        return parts.joined(separator: " · ")
    }

    /// XP per local hour for one day (the activity strip) — or, with `day`
    /// nil, across the last 30 days (best playing hours).
    static func hourlyXP(_ db: Database, day: String?) throws -> [LevelDBHourBucket] {
        let filter = day != nil
            ? "WHERE date(timestamp, 'unixepoch', 'localtime') = ?"
            : "WHERE timestamp >= strftime('%s', 'now', '-30 days')"
        let args: [DatabaseValueConvertible] = day.map { [$0] } ?? []
        let sql = """
        SELECT CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS hour,
               COALESCE(sum(xp_gained), 0) AS xp, count(*) AS kills
        FROM kills \(filter) GROUP BY hour ORDER BY hour
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.map {
            LevelDBHourBucket(hour: $0["hour"] ?? 0, xp: $0["xp"] ?? 0, kills: $0["kills"] ?? 0)
        }
    }

    // MARK: - Pace + projection

    static func pace(_ db: Database, now: Date) throws -> LevelDBPace {
        var pace = LevelDBPace()
        // Per-level durations in the CURRENT band, idle-capped is too clever —
        // median is already outlier-resistant against meal breaks.
        let durations = try levelDurations(db)
        pace.medianLevelSeconds = Self.median(durations)
        pace.recentLevelSeconds = Self.median(Array(durations.suffix(10)))
        pace.hourly = try hourlyXP(db, day: nil)

        for (days, keyPath) in [(7, \LevelDBPace.xpPerHour7d), (30, \LevelDBPace.xpPerHour30d)] {
            let windowSQL = """
            SELECT COALESCE(sum(xp_gained), 0) AS xp,
                   COALESCE(sum(min(gap, \(idleCutoffSeconds))), 0) AS active
            FROM (
              SELECT timestamp, xp_gained,
                     timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS gap
              FROM kills WHERE timestamp >= ?
            )
            """
            let since = Int(now.timeIntervalSince1970) - days * 86400
            let row = try Row.fetchOne(db, sql: windowSQL, arguments: [since])
            let xp: Int = row?["xp"] ?? 0
            let active: Int = row?["active"] ?? 0
            if active > 600 { pace[keyPath: keyPath] = Double(xp) / (Double(active) / 3600) }
            if days == 7, active > 0 {
                let daysSQL = """
                SELECT count(DISTINCT date(timestamp, 'unixepoch', 'localtime'))
                FROM kills WHERE timestamp >= ?
                """
                let played = try Int.fetchOne(db, sql: daysSQL, arguments: [since]) ?? 1
                pace.activeSecondsPerDay7d = Double(active) / Double(max(played, 1))
            }
        }

        // Where am I + how far to the remort ceiling, at the recent pace.
        if let last = try Row.fetchOne(
            db, sql: "SELECT level FROM level_events ORDER BY timestamp DESC LIMIT 1"
        ) {
            let level: Int = last["level"] ?? 0
            pace.currentLevel = level
            let perLevel = pace.recentLevelSeconds ?? pace.medianLevelSeconds
            let perDay = pace.activeSecondsPerDay7d ?? 0
            if let perLevel, perDay > 0, level < Self.remortCeiling {
                let remaining = Double(Self.remortCeiling - level) * perLevel
                pace.daysToRemort = remaining / perDay
            }
        }
        return pace
    }

    /// Seconds between consecutive levels in the latest band, oldest first.
    static func levelDurations(_ db: Database) throws -> [Double] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS gap
        FROM level_events
        WHERE (tier, remort) = (SELECT tier, remort FROM level_events
                                ORDER BY timestamp DESC LIMIT 1)
        """)
        return rows.compactMap { row -> Double? in
            guard let gap: Int = row["gap"], gap > 0 else { return nil }
            return Double(gap)
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Economics

    static func economics(_ db: Database) throws -> [LevelDBActivityEconomics] {
        var rows: [LevelDBActivityEconomics] = []
        for (table, label, successResults) in [
            ("campaigns", "Campaigns", "('completed')"),
            ("quests", "Quests", "('completed')"),
            ("gquests", "Global quests", "('won', 'completed')")
        ] {
            guard let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS n,
                   avg(CASE WHEN result IN \(successResults) THEN 1.0
                            WHEN result IS NULL THEN NULL ELSE 0.0 END) AS success,
                   avg(CASE WHEN result IN \(successResults) THEN duration END) AS dur,
                   avg(CASE WHEN result IN \(successResults) THEN qp END) AS qp,
                   avg(CASE WHEN result IN \(successResults) THEN gold END) AS gold,
                   avg(CASE WHEN result IN \(successResults) THEN tp END) AS tp
            FROM \(table)
            """), let count: Int = row["n"], count > 0 else { continue }
            var entry = LevelDBActivityEconomics(activity: label, count: count)
            entry.successRate = row["success"]
            entry.avgDurationSeconds = row["dur"]
            entry.avgQP = row["qp"]
            entry.avgGold = row["gold"]
            entry.avgTP = row["tp"]
            if let qp = entry.avgQP, let dur = entry.avgDurationSeconds, dur > 0 {
                entry.qpPerMinute = qp / (dur / 60)
            }
            rows.append(entry)
        }
        return rows
    }

    // MARK: - Records

    static func records(_ db: Database, days: [LevelDBDaySummary], now: Date) throws -> LevelDBRecords {
        var records = LevelDBRecords()
        records.bests = try bests(db, days: days)
        records.lifetime = try lifetime(db)
        records.remorts = try remortRows(db)
        let streaks = Self.streaks(days: days, now: now)
        records.currentStreak = streaks.current
        records.longestStreak = streaks.longest
        return records
    }

    private static func bests(_ db: Database, days: [LevelDBDaySummary]) throws -> [LevelDBRecords.Best] {
        var bests: [LevelDBRecords.Best] = []

        if let fastest = try Row.fetchOne(db, sql: """
        SELECT gap, level, day FROM (
          SELECT timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS gap,
                 level, date(timestamp, 'unixepoch', 'localtime') AS day
          FROM level_events
        ) WHERE gap > 30 ORDER BY gap ASC LIMIT 1
        """), let gap: Int = fastest["gap"] {
            bests.append(.init(
                label: "Fastest level",
                value: LevelDBFormatCompact.duration(Double(gap)) + " (to \(fastest["level"] ?? 0))",
                when: fastest["day"] ?? ""
            ))
        }
        if let top = days.max(by: { $0.xp < $1.xp }), top.xp > 0 {
            bests.append(.init(
                label: "Biggest XP day", value: LevelDBFormatCompact.compact(top.xp), when: top.day
            ))
        }
        if let top = days.max(by: { $0.levels < $1.levels }), top.levels > 0 {
            bests.append(.init(
                label: "Most levels in a day", value: "\(top.levels)", when: top.day
            ))
        }
        if let top = days.max(by: { $0.pups < $1.pups }), top.pups > 0 {
            bests.append(.init(label: "Most pups in a day", value: "\(top.pups)", when: top.day))
        }
        if let top = days.max(by: { $0.qpEarned < $1.qpEarned }), top.qpEarned > 0 {
            bests.append(.init(label: "Richest QP day", value: "\(top.qpEarned) qp", when: top.day))
        }
        if let fastCP = try Row.fetchOne(db, sql: """
        SELECT duration, date(timestamp, 'unixepoch', 'localtime') AS day, mob_count
        FROM campaigns WHERE result = 'completed' AND duration > 0
        ORDER BY duration ASC LIMIT 1
        """), let dur: Int = fastCP["duration"] {
            bests.append(.init(
                label: "Fastest campaign",
                value: LevelDBFormatCompact.duration(Double(dur)) + " (\(fastCP["mob_count"] ?? 0) mobs)",
                when: fastCP["day"] ?? ""
            ))
        }

        return bests
    }

    private static func lifetime(_ db: Database) throws -> [LevelDBRecords.Best] {
        let totals = try Row.fetchOne(db, sql: """
        SELECT (SELECT count(*) FROM kills) AS kills,
               (SELECT COALESCE(sum(xp_gained), 0) FROM kills) AS xp,
               (SELECT count(*) FROM deaths) AS deaths,
               (SELECT count(*) FROM level_events) AS levels,
               (SELECT count(*) FROM pup_events) AS pups,
               (SELECT count(*) FROM campaigns WHERE result = 'completed') AS cps,
               (SELECT count(*) FROM quests WHERE result = 'completed') AS quests,
               (SELECT count(*) FROM gquests) AS gqs,
               (SELECT COALESCE(sum(qp), 0) FROM quests) +
               (SELECT COALESCE(sum(qp), 0) FROM campaigns) +
               (SELECT COALESCE(sum(qp), 0) FROM gquests) AS qp
        """)
        guard let totals else { return [] }
        let kills: Int = totals["kills"] ?? 0
        let deaths: Int = totals["deaths"] ?? 0
        return [
            .init(label: "Kills", value: LevelDBFormatCompact.grouped(kills), when: ""),
            .init(label: "XP", value: LevelDBFormatCompact.compact(totals["xp"] ?? 0), when: ""),
            .init(label: "Levels", value: LevelDBFormatCompact.grouped(totals["levels"] ?? 0), when: ""),
            .init(label: "Pups", value: LevelDBFormatCompact.grouped(totals["pups"] ?? 0), when: ""),
            .init(label: "Campaigns", value: LevelDBFormatCompact.grouped(totals["cps"] ?? 0), when: ""),
            .init(label: "Quests", value: LevelDBFormatCompact.grouped(totals["quests"] ?? 0), when: ""),
            .init(
                label: "Global quests",
                value: LevelDBFormatCompact.grouped(totals["gqs"] ?? 0),
                when: ""
            ),
            .init(label: "QP earned", value: LevelDBFormatCompact.grouped(totals["qp"] ?? 0), when: ""),
            .init(
                label: "Deaths",
                value: deaths == 0
                    ? "0"
                    : "\(deaths) (1 per \(LevelDBFormatCompact.grouped(kills / max(deaths, 1))) kills)",
                when: ""
            )
        ]
    }

    private static func remortRows(_ db: Database) throws -> [LevelDBRecords.RemortRow] {
        var remorts: [LevelDBRecords.RemortRow] = []
        // Per-remort speed comparison.
        let remortRows = try Row.fetchAll(db, sql: """
        SELECT tier, remort, count(*) AS levels FROM level_events
        WHERE tier IS NOT NULL AND remort IS NOT NULL
        GROUP BY tier, remort ORDER BY tier, remort
        """)
        for row in remortRows {
            let tier: Int = row["tier"] ?? 0
            let remort: Int = row["remort"] ?? 0
            let gapSQL = """
            SELECT timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS gap
            FROM level_events WHERE tier = ? AND remort = ?
            """
            let gaps = try Row.fetchAll(db, sql: gapSQL, arguments: [tier, remort])
                .compactMap { r -> Double? in
                    guard let gap: Int = r["gap"], gap > 0 else { return nil }
                    return Double(gap)
                }
            remorts.append(.init(
                tier: tier,
                remort: remort,
                levels: row["levels"] ?? 0,
                medianLevelSeconds: Self.median(gaps)
            ))
        }

        return remorts
    }

    /// Consecutive-days-played streaks (the days list arrives newest-first).
    static func streaks(days: [LevelDBDaySummary], now: Date) -> (current: Int, longest: Int) {
        let played = Set(days.map(\.day))
        var streak = 0
        var calendar = Calendar.current
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var cursor = now
        // The current streak may start today or yesterday.
        if !played.contains(formatter.string(from: cursor)) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while played.contains(formatter.string(from: cursor)) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var longest = 0
        var run = 0
        var previous: Date?
        for day in days.reversed() {
            guard let date = formatter.date(from: day.day) else { continue }
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return (streak, longest)
    }
}

/// Local formatting used by the store-side record strings (the UI's
/// LevelDBFormat lives in MudUI; these stay in MudCore for testability).
enum LevelDBFormatCompact {
    static func compact(_ value: Int) -> String {
        let n = Double(value)
        switch abs(value) {
        case 1_000_000_000...: return trim(n / 1_000_000_000) + "B"
        case 1_000_000...: return trim(n / 1_000_000) + "M"
        case 10000...: return trim(n / 1000) + "k"
        default: return grouped(value)
        }
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func trim(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

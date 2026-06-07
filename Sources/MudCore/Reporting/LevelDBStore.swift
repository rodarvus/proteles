import Foundation
import GRDB

/// **Read-only** access to the leveldb plugin's SQLite file (`leveldb.db`),
/// feeding the native reporting panels (PLAN.md D-71). The leveldb Lua plugin is
/// the sole writer (it runs verbatim through the compat shim); Proteles only
/// reads — the same decoupling the mapper uses for `Aardwolf.db`. Opening the
/// file in read-only mode means a running plugin's WAL writes never block us and
/// we can never corrupt its data.
///
/// `Sendable` over GRDB's serialized `DatabaseQueue`; all queries are pure
/// aggregates so the whole type is unit-testable against a fixture DB.
public final class LevelDBStore: Sendable {
    public enum StoreError: Error, Equatable {
        case openFailed(String)
        case readFailed(String)
    }

    /// How the zone-efficiency report is ordered.
    public enum ZoneSort: String, Sendable, CaseIterable, Codable {
        case xpPerSecond
        case xp
        case kills
        case gold

        public var label: String {
            switch self {
            case .xpPerSecond: "XP / sec"
            case .xp: "Total XP"
            case .kills: "Kills"
            case .gold: "Gold"
            }
        }
    }

    public let url: URL
    private let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        self.url = url
        do {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA busy_timeout = 2000")
            }
            dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw StoreError.openFailed(error.localizedDescription)
        }
    }

    /// The leveldb plugin writes `Databases/<character>/leveldb.db` (flat, via
    /// `proteles.databaseDir()`, #43/#44). Returns that URL (whether or not the
    /// file exists yet).
    public static func defaultURL(character: String, fileManager: FileManager = .default) throws -> URL {
        try ProtelesPaths.pluginDatabaseURL(
            character: character, fileName: "leveldb.db", fileManager: fileManager
        )
    }

    /// `true` when the DB file exists (the plugin has been run at least once).
    public static func databaseExists(character: String, fileManager: FileManager = .default) -> Bool {
        guard let url = try? defaultURL(character: character, fileManager: fileManager) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Band filtering

    /// Build a `tier`/`remort` filter for `band`. Returns the SQL fragment
    /// (without a leading `WHERE`/`AND`) and its bound arguments; empty when the
    /// band is unconstrained.
    private static func bandFilter(_ band: LevelDBBand) -> (sql: String, args: [DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        if let tier = band.tier { clauses.append("tier = ?"); args.append(tier) }
        if let remort = band.remort { clauses.append("remort = ?"); args.append(remort) }
        return (clauses.joined(separator: " AND "), args)
    }

    /// Prefix a band filter with `WHERE`/`AND` and optionally extra clauses.
    private static func whereClause(
        _ band: LevelDBBand, extra: [String] = []
    ) -> (sql: String, args: [DatabaseValueConvertible]) {
        let filter = bandFilter(band)
        var clauses = extra
        if !filter.sql.isEmpty { clauses.append(filter.sql) }
        let sql = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return (sql, filter.args)
    }

    // MARK: - Whole-report load

    /// Load every report for one `band` selection in a single read transaction.
    /// `now` is injectable for deterministic tests of the live/daily windows.
    public func load(
        band: LevelDBBand,
        sort: ZoneSort = .xpPerSecond,
        now: Date = Date()
    ) throws -> LevelDBReport {
        do {
            return try dbQueue.read { db in
                var report = LevelDBReport()
                report.band = band
                report.summary = try Self.summary(db)
                report.zones = try Self.zones(db, band: band, sort: sort)
                report.mobs = try Self.mobs(db, band: band)
                report.quests = try Self.objective(db, table: "quests", band: band)
                report.campaigns = try Self.objective(db, table: "campaigns", band: band)
                report.globalQuests = try Self.objective(db, table: "gquests", band: band)
                report.deaths = try Self.deaths(db, band: band)
                report.daily = try Self.daily(db)
                report.levelCurve = try Self.levelCurve(db)
                report.goldSources = try Self.goldSources(db)
                report.chapters = try Self.chapters(db)
                report.bands = try Self.bands(db)
                report.live = try Self.live(db, band: report.summary.currentBand, now: now)
                return report
            }
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    // MARK: - Individual queries (static, so they're trivially testable)

    static func summary(_ db: Database) throws -> LevelDBSummary {
        var summary = LevelDBSummary()
        if let row = try Row.fetchOne(db, sql: """
        SELECT count(*) AS k, COALESCE(sum(xp_gained), 0) AS xp FROM kills
        """) {
            summary.totalKills = row["k"] ?? 0
            summary.totalXP = row["xp"] ?? 0
        }
        summary.totalGold = try Int.fetchOne(
            db, sql: "SELECT COALESCE(sum(amount), 0) FROM events WHERE category = 'gold'"
        ) ?? 0
        summary.totalDeaths = try Int.fetchOne(db, sql: "SELECT count(*) FROM deaths") ?? 0
        summary.totalQuests = try Int.fetchOne(db, sql: "SELECT count(*) FROM quests") ?? 0
        summary.totalCampaigns = try Int.fetchOne(db, sql: "SELECT count(*) FROM campaigns") ?? 0
        if let row = try Row.fetchOne(db, sql: """
        SELECT level, tier, remort FROM kills ORDER BY timestamp DESC LIMIT 1
        """) {
            summary.currentLevel = row["level"] ?? 0
            summary.currentTier = row["tier"]
            summary.currentRemort = row["remort"]
        }
        summary.bestDay = try daily(db, limit: 1, order: "xp DESC").first
        return summary
    }

    static func zones(_ db: Database, band: LevelDBBand, sort: ZoneSort) throws -> [LevelDBZoneStat] {
        let order = switch sort {
        case .xpPerSecond: "xp_per_sec DESC"
        case .xp: "xp DESC"
        case .kills: "kills DESC"
        case .gold: "gold DESC"
        }
        let clause = whereClause(band, extra: ["zone <> ''"])
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT zone,
                   count(*) AS kills,
                   COALESCE(sum(xp_gained), 0) AS xp,
                   COALESCE(sum(gold_gained), 0) AS gold,
                   COALESCE(sum(combat_time), 0) AS secs,
                   COALESCE(sum(xp_gained), 0) * 1.0 / NULLIF(sum(combat_time), 0) AS xp_per_sec
            FROM kills \(clause.sql)
            GROUP BY zone HAVING kills >= 5
            ORDER BY \(order) NULLS LAST
            LIMIT 60
            """,
            arguments: StatementArguments(clause.args)
        )
        return rows.map { row in
            LevelDBZoneStat(
                zone: row["zone"] ?? "?",
                kills: row["kills"] ?? 0,
                xp: row["xp"] ?? 0,
                gold: row["gold"] ?? 0,
                combatSeconds: row["secs"] ?? 0
            )
        }
    }

    static func mobs(_ db: Database, band: LevelDBBand) throws -> [LevelDBMobStat] {
        let clause = whereClause(band)
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT mob_name, zone, count(*) AS kills, COALESCE(sum(xp_gained), 0) AS xp
            FROM kills \(clause.sql)
            GROUP BY mob_name, zone
            ORDER BY kills DESC LIMIT 60
            """,
            arguments: StatementArguments(clause.args)
        )
        return rows.map { row in
            LevelDBMobStat(
                mob: row["mob_name"] ?? "?",
                zone: row["zone"] ?? "",
                kills: row["kills"] ?? 0,
                xp: row["xp"] ?? 0
            )
        }
    }

    /// Aggregate a quest-like table (`quests`/`campaigns`/`gquests`), all of
    /// which carry `result`, `qp`, `gold`, `trains`, `pracs`, `duration`.
    static func objective(_ db: Database, table: String, band: LevelDBBand) throws -> LevelDBObjectiveStat {
        let clause = whereClause(band)
        var stat = LevelDBObjectiveStat()
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT count(*) AS n,
                   COALESCE(sum(CASE WHEN lower(COALESCE(result, ''))
                     IN ('success', 'completed', 'complete', 'pass') THEN 1 ELSE 0 END), 0) AS ok,
                   COALESCE(sum(qp), 0) AS qp,
                   COALESCE(sum(gold), 0) AS gold,
                   COALESCE(sum(trains), 0) AS trains,
                   COALESCE(sum(pracs), 0) AS pracs,
                   COALESCE(sum(duration), 0) AS dur
            FROM \(table) \(clause.sql)
            """,
            arguments: StatementArguments(clause.args)
        ) else { return stat }
        stat.attempts = row["n"] ?? 0
        stat.succeeded = row["ok"] ?? 0
        stat.totalQP = row["qp"] ?? 0
        stat.totalGold = row["gold"] ?? 0
        stat.totalTrains = row["trains"] ?? 0
        stat.totalPracs = row["pracs"] ?? 0
        stat.totalDuration = row["dur"] ?? 0
        return stat
    }

    static func deaths(_ db: Database, band: LevelDBBand) throws -> [LevelDBDeath] {
        let clause = whereClause(band)
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT timestamp, mob_name, zone, level FROM deaths \(clause.sql)
            ORDER BY timestamp DESC LIMIT 100
            """,
            arguments: StatementArguments(clause.args)
        )
        return rows.map { row in
            LevelDBDeath(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                mob: row["mob_name"] ?? "something",
                zone: row["zone"] ?? "?",
                level: row["level"] ?? 0
            )
        }
    }

    static func daily(_ db: Database, limit: Int = 120, order: String = "day DESC") throws -> [LevelDBDaily] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
               count(*) AS kills, COALESCE(sum(xp_gained), 0) AS xp
        FROM kills GROUP BY day ORDER BY \(order) LIMIT \(limit)
        """)
        return rows.compactMap { row in
            guard let day: String = row["day"] else { return nil }
            return LevelDBDaily(day: day, kills: row["kills"] ?? 0, xp: row["xp"] ?? 0)
        }
    }

    static func levelCurve(_ db: Database) throws -> [LevelDBLevelPoint] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT timestamp, level, tier, remort FROM level_events ORDER BY timestamp ASC
        """)
        return rows.map { row in
            LevelDBLevelPoint(
                timestamp: Date(timeIntervalSince1970: row["timestamp"] ?? 0),
                level: row["level"] ?? 0,
                tier: row["tier"],
                remort: row["remort"]
            )
        }
    }

    static func goldSources(_ db: Database) throws -> [LevelDBGoldSource] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT source, COALESCE(sum(amount), 0) AS amount FROM events
        WHERE category = 'gold' GROUP BY source ORDER BY amount DESC LIMIT 12
        """)
        return rows.map { LevelDBGoldSource(source: $0["source"] ?? "?", amount: $0["amount"] ?? 0) }
    }

    /// Distinct tier/remort bands that have kills, newest activity first — the
    /// filter menu and the journey's chapter list.
    static func bands(_ db: Database) throws -> [LevelDBBand] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT tier, remort, max(timestamp) AS last FROM kills
        WHERE tier IS NOT NULL AND remort IS NOT NULL
        GROUP BY tier, remort ORDER BY last DESC
        """)
        return rows.map { LevelDBBand(tier: $0["tier"], remort: $0["remort"]) }
    }

    static func chapters(_ db: Database) throws -> [LevelDBChapter] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT k.tier AS tier, k.remort AS remort,
               count(*) AS kills,
               min(k.level) AS minlvl, max(k.level) AS maxlvl,
               min(k.timestamp) AS first, max(k.timestamp) AS last
        FROM kills k
        WHERE k.tier IS NOT NULL AND k.remort IS NOT NULL
        GROUP BY k.tier, k.remort ORDER BY last DESC
        """)
        var chapters: [LevelDBChapter] = []
        for row in rows {
            let band = LevelDBBand(tier: row["tier"], remort: row["remort"])
            let deaths = try deathCount(db, band: band)
            let best = try topZone(db, band: band)
            chapters.append(LevelDBChapter(
                band: band,
                kills: row["kills"] ?? 0,
                deaths: deaths,
                minLevel: row["minlvl"] ?? 0,
                maxLevel: row["maxlvl"] ?? 0,
                bestZone: best,
                firstSeen: (row["first"] as Double?).map { Date(timeIntervalSince1970: $0) },
                lastSeen: (row["last"] as Double?).map { Date(timeIntervalSince1970: $0) }
            ))
        }
        return chapters
    }

    private static func deathCount(_ db: Database, band: LevelDBBand) throws -> Int {
        let clause = whereClause(band)
        return try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM deaths \(clause.sql)",
            arguments: StatementArguments(clause.args)
        ) ?? 0
    }

    private static func topZone(_ db: Database, band: LevelDBBand) throws -> String? {
        let clause = whereClause(band, extra: ["zone <> ''"])
        return try String.fetchOne(
            db,
            sql: """
            SELECT zone FROM kills \(clause.sql)
            GROUP BY zone HAVING count(*) >= 5
            ORDER BY COALESCE(sum(xp_gained), 0) * 1.0 / NULLIF(sum(combat_time), 0) DESC NULLS LAST
            LIMIT 1
            """,
            arguments: StatementArguments(clause.args)
        )
    }

    // MARK: - Live HUD

    static func live(_ db: Database, band: LevelDBBand, now: Date) throws -> LevelDBLiveStats {
        var live = LevelDBLiveStats()
        let nowTS = now.timeIntervalSince1970
        let startOfDay = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let hourAgo = nowTS - 3600

        if let row = try Row.fetchOne(
            db,
            sql: """
            SELECT count(*) AS k, COALESCE(sum(xp_gained), 0) AS xp,
                   COALESCE(sum(gold_gained), 0) AS gold
            FROM kills WHERE timestamp >= ?
            """,
            arguments: [startOfDay]
        ) {
            live.todayKills = row["k"] ?? 0
            live.todayXP = row["xp"] ?? 0
            live.todayGold = row["gold"] ?? 0
        }
        if let row = try Row.fetchOne(
            db,
            sql: """
            SELECT count(*) AS k, COALESCE(sum(xp_gained), 0) AS xp,
                   COALESCE(avg(combat_time), 0) AS secs
            FROM kills WHERE timestamp >= ?
            """,
            arguments: [hourAgo]
        ) {
            live.lastHourKills = row["k"] ?? 0
            live.lastHourXP = row["xp"] ?? 0
            live.recentCombatSeconds = row["secs"] ?? 0
        }
        live.bestZone = try zones(db, band: band, sort: .xpPerSecond).first
        // Mean XP per level in this band = band XP / number of level-ups in it.
        let clause = whereClause(band)
        let bandXP = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(sum(xp_gained), 0) FROM kills \(clause.sql)",
            arguments: StatementArguments(clause.args)
        ) ?? 0
        let levelClause = whereClause(band)
        let levels = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM level_events \(levelClause.sql)",
            arguments: StatementArguments(levelClause.args)
        ) ?? 0
        live.xpPerLevelEstimate = levels > 0 ? Double(bandXP) / Double(levels) : 0
        return live
    }
}

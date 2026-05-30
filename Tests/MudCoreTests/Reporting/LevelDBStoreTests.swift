import Foundation
import GRDB
@testable import MudCore
import Testing

/// ``LevelDBStore`` reads the leveldb plugin's SQLite file read-only and
/// aggregates it into the report models the native panels render. These tests
/// build a small fixture DB (the leveldb schema + a handful of rows) and assert
/// the queries — no live DB, no UI.
@Suite("LevelDBStore — read-only reporting")
struct LevelDBStoreTests {
    /// A fixed clock so the live/daily windows are deterministic.
    /// 2026-05-30 12:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_780_142_400)

    // MARK: - Fixture

    private static let schema = """
    CREATE TABLE kills (id INTEGER PRIMARY KEY, timestamp INTEGER, mob_name TEXT,
      zone TEXT, level INTEGER, xp_gained INTEGER, gold_gained INTEGER,
      combat_time REAL, tier INTEGER, remort INTEGER);
    CREATE TABLE deaths (id INTEGER PRIMARY KEY, timestamp INTEGER, mob_name TEXT,
      zone TEXT, level INTEGER, tier INTEGER, remort INTEGER);
    CREATE TABLE quests (id INTEGER PRIMARY KEY, timestamp INTEGER, level INTEGER,
      tier INTEGER, remort INTEGER, result TEXT, duration INTEGER, qp INTEGER,
      gold INTEGER, trains INTEGER, pracs INTEGER);
    CREATE TABLE campaigns (id INTEGER PRIMARY KEY, timestamp INTEGER, level INTEGER,
      tier INTEGER, remort INTEGER, result TEXT, duration INTEGER, qp INTEGER,
      gold INTEGER, trains INTEGER, pracs INTEGER);
    CREATE TABLE gquests (id INTEGER PRIMARY KEY, timestamp INTEGER, level INTEGER,
      tier INTEGER, remort INTEGER, result TEXT, duration INTEGER, qp INTEGER,
      gold INTEGER, trains INTEGER, pracs INTEGER);
    CREATE TABLE level_events (id INTEGER PRIMARY KEY, timestamp INTEGER,
      level INTEGER, tier INTEGER, remort INTEGER);
    CREATE TABLE events (id INTEGER PRIMARY KEY, timestamp INTEGER, category TEXT,
      source TEXT, amount INTEGER);
    """

    private static let killSQL = """
    INSERT INTO kills
      (timestamp, mob_name, zone, level, xp_gained, gold_gained, combat_time, tier, remort)
    VALUES (?, ?, ?, 70, ?, 10, ?, ?, ?)
    """

    /// (ts, mob, zone, xp, combat, tier, remort) kill rows for the fixture.
    private func killRows(base: Double) -> [[DatabaseValueConvertible]] {
        var rows: [[DatabaseValueConvertible]] = []
        // Band T4 R5: verume is efficient (200 XP/sec), sewer is not.
        for index in 0..<10 {
            rows.append([base - Double(index) * 60, "a knight", "verume", 1000, 5.0, 4, 5])
        }
        for index in 0..<5 {
            rows.append([base - Double(index) * 60, "a rat", "sewer", 200, 20.0, 4, 5])
        }
        // An older band (T3 R7) so chapters/bands have >1 entry.
        rows.append([base - 1_000_000, "a goblin", "fortune", 500, 8.0, 3, 7])
        return rows
    }

    /// Create a fixture leveldb DB on disk and return its URL.
    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("leveldb-test-\(UUID().uuidString).db")
        let queue = try DatabaseQueue(path: url.path)
        let base = now.timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: Self.schema)
            for row in killRows(base: base) {
                try db.execute(sql: Self.killSQL, arguments: StatementArguments(row))
            }
            try db.execute(
                sql: """
                INSERT INTO deaths (timestamp, mob_name, zone, level, tier, remort)
                VALUES (?, ?, ?, 70, 4, 5)
                """,
                arguments: [base - 120, "a dragon", "verume"]
            )
            try insertQuest(db, ts: base, result: "success", qp: 30, duration: 600)
            try insertQuest(db, ts: base, result: "failed", qp: 0, duration: 300)
            for (ts, level) in [(base - 3600, 70), (base, 71)] {
                try db.execute(
                    sql: "INSERT INTO level_events (timestamp, level, tier, remort) VALUES (?, ?, 4, 5)",
                    arguments: [ts, level]
                )
            }
            for (source, amount) in [("mob", 5000), ("sell", 3000)] {
                try db.execute(
                    sql: "INSERT INTO events (timestamp, category, source, amount) VALUES (?, 'gold', ?, ?)",
                    arguments: [base, source, amount]
                )
            }
        }
        return url
    }

    private func insertQuest(_ db: Database, ts: Double, result: String, qp: Int, duration: Int) throws {
        try db.execute(
            sql: """
            INSERT INTO quests (timestamp, level, tier, remort, result, duration, qp, gold, trains, pracs)
            VALUES (?, 70, 4, 5, ?, ?, ?, 1000, 1, 1)
            """,
            arguments: [ts, result, duration, qp]
        )
    }

    // MARK: - Tests

    @Test("summary totals + current band")
    func summary() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try LevelDBStore(url: url).load(band: .all, now: now)

        #expect(report.summary.totalKills == 16)
        #expect(report.summary.totalXP == 10 * 1000 + 5 * 200 + 500)
        #expect(report.summary.totalGold == 8000)
        #expect(report.summary.totalDeaths == 1)
        #expect(report.summary.currentTier == 4)
        #expect(report.summary.currentRemort == 5)
    }

    @Test("zone efficiency ranks by XP/sec and respects the band filter")
    func zones() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try LevelDBStore(url: url).load(band: LevelDBBand(tier: 4, remort: 5), now: now)

        // Only T4 R5 zones (verume, sewer); fortune is in another band.
        #expect(report.zones.map(\.zone) == ["verume", "sewer"])
        let verume = try #require(report.zones.first)
        // 10 kills × 1000 XP over 10 × 5s = 50s → 200 XP/sec.
        #expect(verume.xpPerSecond == 200)
        #expect(verume.kills == 10)
    }

    @Test("objective aggregation: success rate + averages")
    func quests() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try LevelDBStore(url: url).load(band: LevelDBBand(tier: 4, remort: 5), now: now)

        #expect(report.quests.attempts == 2)
        #expect(report.quests.succeeded == 1)
        #expect(report.quests.successRate == 0.5)
        #expect(report.quests.totalQP == 30)
    }

    @Test("bands + chapters cover each tier/remort, newest first")
    func bandsAndChapters() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try LevelDBStore(url: url).load(band: .all, now: now)

        #expect(report.bands == [LevelDBBand(tier: 4, remort: 5), LevelDBBand(tier: 3, remort: 7)])
        #expect(report.chapters.count == 2)
        let current = try #require(report.chapters.first)
        #expect(current.band == LevelDBBand(tier: 4, remort: 5))
        #expect(current.bestZone == "verume")
        #expect(current.deaths == 1)
    }

    @Test("live stats use today + the last hour")
    func live() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try LevelDBStore(url: url).load(band: .all, now: now)

        // All T4R5 kills are within the last ~15 minutes of `now`.
        #expect(report.live.lastHourKills == 15)
        #expect(report.live.lastHourXP == 10 * 1000 + 5 * 200)
        #expect(report.live.bestZone?.zone == "verume")
    }

    @Test("gold sources are ranked by amount")
    func goldSources() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try LevelDBStore(url: url).load(band: .all, now: now)
        #expect(report.goldSources.map(\.source) == ["mob", "sell"])
        #expect(report.goldSources.first?.amount == 5000)
    }
}

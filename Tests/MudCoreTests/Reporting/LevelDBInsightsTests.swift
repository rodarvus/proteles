import Foundation
import GRDB
@testable import MudCore
import Testing

/// The #12 insight queries against a small fixture DB with known rows —
/// schemas mirror the live leveldb.db (verified 2026-06-10).
@Suite("LevelDB — insights (#12)")
struct LevelDBInsightsTests {
    /// Two days of play: day 1 = 3 kills (one 5-min gap, one idle gap),
    /// a level, a completed campaign; day 2 = a pup, a failed quest, a death.
    private func makeStore() throws -> (LevelDBStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ldb-insights-\(UUID().uuidString).db")
        let queue = try DatabaseQueue(path: url.path)
        // Anchor both days at local noon so date() bucketing is stable.
        var calendar = Calendar.current
        calendar.timeZone = .current
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 12))!
        let t1 = Int(day1.timeIntervalSince1970)
        let t2 = Int(day2.timeIntervalSince1970)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE kills (id INTEGER PRIMARY KEY, timestamp INTEGER, xp_gained INTEGER,
                                tier INTEGER, remort INTEGER);
            CREATE TABLE level_events (id INTEGER PRIMARY KEY, timestamp INTEGER, level INTEGER,
                                       tier INTEGER, remort INTEGER);
            CREATE TABLE pup_events (id INTEGER PRIMARY KEY, timestamp INTEGER, tier INTEGER,
                                     remort INTEGER, pup_number INTEGER, zone TEXT);
            CREATE TABLE campaigns (id INTEGER PRIMARY KEY, timestamp INTEGER, level INTEGER,
                                    result TEXT, duration INTEGER, mob_count INTEGER,
                                    qp INTEGER, gold INTEGER, tp INTEGER);
            CREATE TABLE quests (id INTEGER PRIMARY KEY, timestamp INTEGER, level INTEGER,
                                 result TEXT, duration INTEGER, mob_name TEXT, area TEXT,
                                 timer INTEGER, qp INTEGER, gold INTEGER, tp INTEGER);
            CREATE TABLE gquests (id INTEGER PRIMARY KEY, timestamp INTEGER, gq_number INTEGER,
                                  level INTEGER, result TEXT, duration INTEGER,
                                  mob_count INTEGER, qp INTEGER, gold INTEGER, tp INTEGER);
            CREATE TABLE deaths (id INTEGER PRIMARY KEY, timestamp INTEGER, mob_name TEXT,
                                 zone TEXT, level INTEGER);
            CREATE TABLE events (id INTEGER PRIMARY KEY, timestamp INTEGER, category TEXT,
                                 source TEXT, amount INTEGER);
            """)
            // Day 1: kills at +0, +300 (counts), +2000 (capped at 600).
            for (offset, xp) in [(0, 100), (300, 200), (2000, 300)] {
                try db.execute(
                    sql: "INSERT INTO kills (timestamp, xp_gained, tier, remort) VALUES (?, ?, 0, 1)",
                    arguments: [t1 + offset, xp]
                )
            }
            try db.execute(
                sql: "INSERT INTO level_events (timestamp, level, tier, remort) VALUES (?, 100, 0, 1)",
                arguments: [t1 + 400]
            )
            try db.execute(sql: """
            INSERT INTO campaigns (timestamp, level, result, duration, mob_count, qp, gold, tp)
            VALUES (?, 100, 'completed', 600, 8, 20, 5000, 1)
            """, arguments: [t1 + 500])
            // Day 2: a pup, a failed quest, a death.
            try db.execute(sql: """
            INSERT INTO pup_events (timestamp, tier, remort, pup_number, zone)
            VALUES (?, 9, 7, 61, 'ascent')
            """, arguments: [t2])
            try db.execute(sql: """
            INSERT INTO quests (timestamp, level, result, duration, mob_name, qp, gold, tp)
            VALUES (?, 201, 'failed', 300, 'a yeti', 0, 0, 0)
            """, arguments: [t2 + 60])
            try db.execute(sql: """
            INSERT INTO deaths (timestamp, mob_name, zone, level) VALUES (?, 'a dragon', 'icefall', 201)
            """, arguments: [t2 + 120])
        }
        return try (LevelDBStore(url: url), url)
    }

    @Test("day summaries: per-day counts + idle-capped active time")
    func daySummaries() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try store.insights(now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(bundle.days.count == 2)
        let first = try #require(bundle.days.first { $0.day.hasSuffix("-01") })
        #expect(first.kills == 3)
        #expect(first.xp == 600)
        #expect(first.levels == 1)
        #expect(first.campaignsDone == 1)
        #expect(first.qpEarned == 20)
        // Gaps: 300 (counted) + 1700 (capped at 600) = 900.
        #expect(first.activeSeconds == 900)
        let second = try #require(bundle.days.first { $0.day.hasSuffix("-02") })
        #expect(second.pups == 1)
        #expect(second.deaths == 1)
        #expect(second.questsDone == 0)
    }

    @Test("the day story merges all sources in time order")
    func dayStory() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try store.insights()
        let detail = try store.dayDetail(#require(bundle.days.last).day) // day 1
        #expect(detail.events.map(\.kind) == [.level, .campaign])
        #expect(detail.events[1].detail.contains("+20 qp"))
        let detail2 = try store.dayDetail(#require(bundle.days.first).day) // day 2
        #expect(detail2.events.map(\.kind) == [.pup, .quest, .death])
        #expect(detail2.events[1].isNegative)
        #expect(detail2.events[2].detail.contains("a dragon"))
        // The hourly strip is kill-driven: day 1 has kills, day 2 doesn't.
        #expect(!detail.hourly.isEmpty)
        #expect(detail2.hourly.isEmpty)
    }

    @Test("economics: success rates + qp/minute from completed rows")
    func economics() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try store.insights()
        let cps = try #require(bundle.economics.first { $0.activity == "Campaigns" })
        #expect(cps.count == 1)
        #expect(cps.successRate == 1.0)
        #expect(cps.qpPerMinute == 2.0) // 20 qp / 10 min
        let quests = try #require(bundle.economics.first { $0.activity == "Quests" })
        #expect(quests.successRate == 0.0)
    }

    @Test("records: bests, lifetime totals, streaks")
    func records() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // "now" = day 2 evening → both days form the current streak.
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 20)))
        let bundle = try store.insights(now: now)
        #expect(bundle.records.lifetime.contains { $0.label == "Kills" && $0.value == "3" })
        #expect(bundle.records.bests.contains { $0.label == "Biggest XP day" })
        #expect(bundle.records.currentStreak == 2)
        #expect(bundle.records.longestStreak == 2)
        #expect(bundle.records.remorts.count == 1)
    }
}

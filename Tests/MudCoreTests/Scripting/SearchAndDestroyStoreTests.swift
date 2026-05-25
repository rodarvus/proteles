import Foundation
import GRDB
@testable import MudCore
import Testing

@Suite("SearchAndDestroyStore — schema + incremental import")
struct SearchAndDestroyStoreTests {
    /// A fresh temp .db path, cleaned up by the caller.
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-test-\(UUID().uuidString).db")
    }

    /// Build a v6-shaped `SnDdb.db` at `url` with the given rows.
    private func makeV6Source(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE mobs (
              mob TEXT NOT NULL COLLATE NOCASE, room TEXT NOT NULL COLLATE NOCASE,
              roomid INTEGER NOT NULL, zone TEXT NOT NULL,
              seen_count INTEGER NOT NULL DEFAULT 0, kill_count INTEGER NOT NULL DEFAULT 0,
              UNIQUE(mob, roomid));
            CREATE TABLE area (
              name TEXT NOT NULL, key TEXT NOT NULL, minlvl INTEGER NOT NULL,
              maxlvl INTEGER NOT NULL, lock INTEGER NOT NULL, startRoom INTEGER,
              noquest TEXT, vidblain TEXT, userKey TEXT);
            CREATE TABLE mob_keyword_exceptions (
              area_name TEXT NOT NULL, mob_name TEXT NOT NULL, keyword TEXT NOT NULL,
              UNIQUE(area_name, mob_name));
            CREATE TABLE history (
              id INTEGER PRIMARY KEY, type INTEGER NOT NULL, level_taken INTEGER NOT NULL,
              start_time INTEGER NOT NULL, end_time INTEGER, status INTEGER DEFAULT 1,
              qp_rewards INTEGER DEFAULT 0, tp_rewards INTEGER DEFAULT 0,
              train_rewards INTEGER DEFAULT 0, prac_rewards INTEGER DEFAULT 0,
              gold_rewards INTEGER DEFAULT 0);
            INSERT INTO mobs (mob, room, roomid, zone, seen_count, kill_count) VALUES
              ('a city guard', 'Gate House', 1001, 'aylor', 5, 2),
              ('the gatekeeper', 'Main Gate', 1002, 'aylor', 3, 0);
            INSERT INTO area (name, key, minlvl, maxlvl, lock) VALUES
              ('Aylor', 'aylor', 1, 200, 0),
              ('Chakra', 'chakra', 15, 30, 0);
            INSERT INTO mob_keyword_exceptions (area_name, mob_name, keyword) VALUES
              ('aylor', 'a city guard', 'guard');
            INSERT INTO history (id, type, level_taken, start_time, status) VALUES
              (1, 1, 50, 1000, 2);
            """)
        }
    }

    @Test("A fresh store creates S&D's v6 schema and stamps user_version = 6")
    func freshSchema() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SearchAndDestroyStore(url: url)

        #expect(try store.userVersion() == 6)
        #expect(try store.count(of: "mobs") == 0)
        #expect(try store.count(of: "area") == 0)
        #expect(try store.count(of: "mob_keyword_exceptions") == 0)
        #expect(try store.count(of: "history") == 0)
    }

    @Test("Importing a v6 SnDdb.db merges every table")
    func importV6() throws {
        let sourceURL = tempURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try makeV6Source(at: sourceURL)

        let destURL = tempURL()
        defer { try? FileManager.default.removeItem(at: destURL) }
        let dest = try SearchAndDestroyStore(url: destURL)

        let summary = try dest.importIncremental(from: sourceURL)
        #expect(summary.mobs == 2)
        #expect(summary.areas == 2)
        #expect(summary.keywords == 1)
        #expect(summary.history == 1)
        #expect(try dest.count(of: "mobs") == 2)
        #expect(try dest.count(of: "area") == 2)
    }

    @Test("empty() clears every table so a re-import re-adds everything")
    func emptyClearsAllTables() throws {
        let sourceURL = tempURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try makeV6Source(at: sourceURL)

        let destURL = tempURL()
        defer { try? FileManager.default.removeItem(at: destURL) }
        let dest = try SearchAndDestroyStore(url: destURL)
        _ = try dest.importIncremental(from: sourceURL)

        try dest.empty()
        #expect(try dest.count(of: "mobs") == 0)
        #expect(try dest.count(of: "area") == 0)
        #expect(try dest.count(of: "mob_keyword_exceptions") == 0)
        #expect(try dest.count(of: "history") == 0)
        #expect(try dest.userVersion() == 6) // schema intact

        // A re-import re-adds everything (proves the schema survived empty()).
        let summary = try dest.importIncremental(from: sourceURL)
        #expect(summary.mobs == 2)
        #expect(summary.areas == 2)
    }

    @Test("Re-importing the same DB adds nothing (dedupe is non-destructive)")
    func incrementalDedupe() throws {
        let sourceURL = tempURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try makeV6Source(at: sourceURL)

        let destURL = tempURL()
        defer { try? FileManager.default.removeItem(at: destURL) }
        let dest = try SearchAndDestroyStore(url: destURL)

        _ = try dest.importIncremental(from: sourceURL)
        let second = try dest.importIncremental(from: sourceURL)
        #expect(second.isEmpty)
        // No duplication: counts unchanged.
        #expect(try dest.count(of: "mobs") == 2)
        #expect(try dest.count(of: "area") == 2)
        #expect(try dest.count(of: "mob_keyword_exceptions") == 1)
        #expect(try dest.count(of: "history") == 1)
    }

    @Test("Local mob rows are never overwritten; only new (mob,roomid) pairs land")
    func nonDestructiveMobs() throws {
        let sourceURL = tempURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try makeV6Source(at: sourceURL)

        let destURL = tempURL()
        defer { try? FileManager.default.removeItem(at: destURL) }
        let dest = try SearchAndDestroyStore(url: destURL)

        // Pre-seed dest with a local row that collides on (mob, roomid) with
        // the source's 'a city guard'@1001 but carries different counts.
        let queue = try DatabaseQueue(path: destURL.path)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO mobs (mob, room, roomid, zone, seen_count, kill_count)
            VALUES ('a city guard', 'Gate House', 1001, 'aylor', 99, 42)
            """)
        }

        let summary = try dest.importIncremental(from: sourceURL)
        // Only the gatekeeper (a new roomid) is added; the colliding row is kept.
        #expect(summary.mobs == 1)
        try queue.read { db in
            let kept = try Int.fetchOne(
                db, sql: "SELECT seen_count FROM mobs WHERE mob='a city guard' AND roomid=1001"
            )
            #expect(kept == 99) // local value preserved, not the source's 5
        }
    }

    @Test("A pre-v3 source (mobs.count, no seen_count) maps count → seen_count")
    func tolerateOldMobsSchema() throws {
        let sourceURL = tempURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let queue = try DatabaseQueue(path: sourceURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE mobs (
              mob TEXT NOT NULL, room TEXT NOT NULL, roomid INTEGER NOT NULL,
              zone TEXT NOT NULL, count INTEGER NOT NULL, keyword TEXT NOT NULL);
            INSERT INTO mobs (mob, room, roomid, zone, count, keyword)
            VALUES ('an orc', 'Cave', 2001, 'orcland', 7, 'orc');
            """)
        }

        let destURL = tempURL()
        defer { try? FileManager.default.removeItem(at: destURL) }
        let dest = try SearchAndDestroyStore(url: destURL)
        let summary = try dest.importIncremental(from: sourceURL)
        #expect(summary.mobs == 1)

        let destQueue = try DatabaseQueue(path: destURL.path)
        try destQueue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT seen_count, kill_count FROM mobs WHERE mob='an orc'"
            ))
            #expect(row["seen_count"] as Int? == 7) // mapped from `count`
            #expect(row["kill_count"] as Int? == 0) // defaulted
        }
    }

    @Test("A non-S&D database is rejected")
    func rejectsForeignDatabase() throws {
        let sourceURL = tempURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let queue = try DatabaseQueue(path: sourceURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE unrelated (x INTEGER)")
        }

        let destURL = tempURL()
        defer { try? FileManager.default.removeItem(at: destURL) }
        let dest = try SearchAndDestroyStore(url: destURL)

        #expect(throws: SearchAndDestroyStore.ImportError.notASearchAndDestroyDatabase) {
            try dest.importIncremental(from: sourceURL)
        }
    }
}

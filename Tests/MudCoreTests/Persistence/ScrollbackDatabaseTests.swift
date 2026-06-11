import Foundation
import GRDB
@testable import MudCore
import Testing

@Suite("ScrollbackDatabase — round-trip")
struct ScrollbackDatabaseRoundTripTests {
    @Test("Insert one line, fetch it back exactly")
    func insertAndFetch() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        let line = PersistedLine(
            id: 0,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            text: "hello aardwolf",
            runsJSON: nil
        )
        try db.insert(line)

        let recent = try db.mostRecent(limit: 1)
        #expect(recent == [line])
        try cleanup(db)
    }

    @Test("Insert many in a batch and fetch in append order")
    func insertBatchPreservesOrder() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        let lines = (0..<10).map { id in
            PersistedLine(
                id: Int64(id),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                text: "line-\(id)"
            )
        }
        try db.insertBatch(lines)

        let count = try db.count()
        #expect(count == 10)

        let fetched = try db.mostRecent(limit: 10)
        #expect(fetched.map(\.id) == Array(0..<10).map { Int64($0) })
        try cleanup(db)
    }

    @Test("Round-trip preserves StyledRun content via JSON")
    func roundTripPreservesStyledRuns() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        let bold = StyleAttributes(bold: true)
        let line = Line(
            id: LineID(42),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            text: "you hit the troll for 42 damage.",
            runs: [
                StyledRun(utf16Range: 13..<18, style: bold)
            ]
        )
        let persisted = try PersistedLine(line)
        try db.insert(persisted)

        let fetched = try db.mostRecent(limit: 1)
        let restored = try fetched[0].toLine()
        // Content round-trips exactly; the id deliberately does NOT (the
        // database assigns row ids — per-launch LineIDs are not keys, and
        // ScrollbackStore re-assigns ids on restore anyway).
        #expect(restored.text == line.text)
        #expect(restored.timestamp == line.timestamp)
        #expect(restored.runs == line.runs)
        try cleanup(db)
    }

    @Test("mostRecent returns the newest N when the table has more rows")
    func mostRecentCaps() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        let lines = (0..<50).map {
            PersistedLine(
                id: Int64($0),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)),
                text: "line-\($0)"
            )
        }
        try db.insertBatch(lines)

        let recent = try db.mostRecent(limit: 5)
        #expect(recent.map(\.id) == [45, 46, 47, 48, 49])
        try cleanup(db)
    }
}

@Suite("ScrollbackDatabase — FTS5 search")
struct ScrollbackDatabaseSearchTests {
    @Test("Bareword search returns matching lines, oldest-first")
    func bareWordSearch() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        try db.insertBatch([
            line(id: 0, text: "A wolf snarls at you."),
            line(id: 1, text: "You have 42 health."),
            line(id: 2, text: "The misty wolf approaches."),
            line(id: 3, text: "An ogre roars loudly.")
        ])

        let hits = try db.search("wolf")
        // FTS5's unicode61 tokenizer treats "wolf" and "wolfpack" as
        // distinct tokens, so a search for "wolf" matches only lines
        // where the bare word appears.
        #expect(hits.map(\.id) == [0, 2])
    }

    @Test("Tokenizer does NOT do substring matching")
    func tokenizerDoesNotMatchSubstrings() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        try db.insertBatch([
            line(id: 0, text: "Welcome to Aardwolf!"),
            line(id: 1, text: "A wolf snarls.")
        ])
        // "Aardwolf" is one token; a search for "wolf" matches only the
        // bare-word line.
        let hits = try db.search("wolf")
        #expect(hits.map(\.id) == [1])
    }

    @Test("Multi-word search uses AND semantics")
    func multiWordANDSearch() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        try db.insertBatch([
            line(id: 0, text: "The misty wolf appears."),
            line(id: 1, text: "A misty fog rolls in."),
            line(id: 2, text: "Wolf howls in the distance.")
        ])

        let hits = try db.search("misty wolf")
        #expect(hits.map(\.id) == [0])
    }

    @Test("Empty / whitespace query yields no results")
    func emptyQueryYieldsNothing() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        try db.insertBatch([line(id: 0, text: "anything")])
        #expect(try db.search("").isEmpty)
        #expect(try db.search("   ").isEmpty)
    }

    @Test("Limit caps the result count")
    func limitCaps() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        try db.insertBatch(
            (0..<10).map {
                line(id: Int64($0), text: "wolf attacks for \($0).")
            }
        )
        let hits = try db.search("wolf", limit: 3)
        #expect(hits.count == 3)
        #expect(hits.map(\.id) == [0, 1, 2])
    }

    private func line(id: Int64, text: String) -> PersistedLine {
        PersistedLine(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
            text: text
        )
    }
}

@Suite("ScrollbackDatabase — durability")
struct ScrollbackDatabaseDurabilityTests {
    @Test("Re-opening the same file preserves stored lines")
    func reopenPreservesData() throws {
        let url = temporaryDatabaseURL()
        do {
            let db = try ScrollbackDatabase(url: url)
            try db.insertBatch([
                PersistedLine(
                    id: 0,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    text: "first session"
                )
            ])
        }

        // Re-open
        let db = try ScrollbackDatabase(url: url)
        let recent = try db.mostRecent(limit: 5)
        #expect(recent.map(\.text) == ["first session"])
        try cleanup(db)
    }
}

/// The 2026-06-11 stale-resume incident: v1 keyed rows by the per-launch
/// LineID with REPLACE semantics, so every relaunch overwrote history from
/// id 0 and `mostRecent` (id DESC) returned the OLDEST surviving session.
@Suite("ScrollbackDatabase — append-only across relaunches")
struct ScrollbackDatabaseRelaunchTests {
    private func line(_ id: UInt64, _ text: String, at seconds: TimeInterval) -> Line {
        Line(id: LineID(id), timestamp: Date(timeIntervalSince1970: seconds), text: text)
    }

    @Test("a second launch's lines append instead of overwriting the first's")
    func relaunchAppends() throws {
        let db = try ScrollbackDatabase(url: temporaryDatabaseURL())
        // Launch 1: in-memory LineIDs 0..9.
        let first = try (0..<10).map {
            try PersistedLine(line(UInt64($0), "first-\($0)", at: 1_700_000_000 + Double($0)))
        }
        try db.insertBatch(first)
        // Launch 2 (process restart): LineIDs start at 0 AGAIN. With the v1
        // keying these REPLACED rows 0..4; they must append.
        let second = try (0..<5).map {
            try PersistedLine(line(UInt64($0), "second-\($0)", at: 1_700_001_000 + Double($0)))
        }
        try db.insertBatch(second)

        #expect(try db.count() == 15, "the relaunch overwrote instead of appending")
        let recent = try db.mostRecent(limit: 5)
        #expect(
            recent.map(\.text) == ["second-0", "second-1", "second-2", "second-3", "second-4"],
            "mostRecent must return the NEWEST session's lines"
        )
        try cleanup(db)
    }

    @Test("v2 migration rekeys a v1 database so mostRecent follows time again")
    func v2MigrationRekeys() throws {
        let url = temporaryDatabaseURL()
        // Hand-build the v1 shape: v1 DDL + the v1 migration marker + rows
        // whose id order interleaves sessions (newest TIMESTAMPS on LOW ids,
        // exactly what REPLACE left behind in the live incident).
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)
            """)
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1.scrollback_lines')")
            try db.execute(sql: """
            CREATE TABLE scrollback_lines (
                id INTEGER PRIMARY KEY,
                timestamp DATETIME NOT NULL,
                text TEXT NOT NULL,
                runs_json TEXT
            )
            """)
            try db.execute(sql: """
            CREATE INDEX scrollback_lines_on_timestamp ON scrollback_lines("timestamp")
            """)
            try db.create(virtualTable: "scrollback_lines_fts", using: FTS5()) { fts in
                fts.synchronize(withTable: "scrollback_lines")
                fts.tokenizer = .unicode61()
                fts.column("text")
            }
            // ids 0..2 = TODAY's session (overwrote an older one); ids 10..12
            // = YESTERDAY's surviving rows (the highest ids!).
            for (id, stamp, text) in [
                (0, "2026-06-11 10:00:00", "today-0"),
                (1, "2026-06-11 10:00:01", "today-1"),
                (2, "2026-06-11 10:00:02", "today-2"),
                (10, "2026-06-10 22:00:00", "yesterday-0"),
                (11, "2026-06-10 22:00:01", "yesterday-1"),
                (12, "2026-06-10 22:00:02", "yesterday-2")
            ] {
                try db.execute(
                    sql: "INSERT INTO scrollback_lines (id, timestamp, text) VALUES (?, ?, ?)",
                    arguments: [id, stamp, text]
                )
            }
        }

        // Opening through ScrollbackDatabase runs the v2 migration.
        let db = try ScrollbackDatabase(url: url)
        #expect(try db.count() == 6)
        // v1 behaviour returned yesterday-* here (highest ids). After the
        // rekey, the newest TIMESTAMPS are the newest ids.
        let recent = try db.mostRecent(limit: 3)
        #expect(recent.map(\.text) == ["today-0", "today-1", "today-2"])
        // FTS was rebuilt over the rekeyed table.
        #expect(try db.search("yesterday", limit: 10).count == 3)
        // And new inserts append after everything.
        try db.insert(PersistedLine(timestamp: Date(), text: "fresh"))
        #expect(try db.mostRecent(limit: 1).first?.text == "fresh")
        try cleanup(db)
    }
}

// MARK: - Helpers

private func temporaryDatabaseURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir.appendingPathComponent("proteles-test-\(UUID().uuidString).sqlite")
}

private func cleanup(_ db: ScrollbackDatabase) throws {
    let url = db.url
    // GRDB writes a number of journaling artefacts alongside the
    // main file (`-wal`, `-shm`). Remove the directory entry if it
    // exists; tests are isolated so this is best-effort.
    let fileManager = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        let candidate = URL(
            fileURLWithPath: url.path + suffix
        )
        try? fileManager.removeItem(at: candidate)
    }
}

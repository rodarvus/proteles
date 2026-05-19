import Foundation
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
        #expect(restored == line)
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

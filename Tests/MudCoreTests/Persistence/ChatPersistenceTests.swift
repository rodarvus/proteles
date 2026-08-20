import Foundation
@testable import MudCore
import Testing

/// Chat history persistence (#57) — ``ScrollbackPersistence``'s sibling.
/// Mirrors that suite's coverage, plus the chat-specific pieces: channel/
/// player columns, channel-filtered search, the retention prune, and the
/// seed-before-attach restore that must never re-persist.
@Suite("ChatPersistence", .serialized)
struct ChatPersistenceTests {
    @Test("default flush cadence bounds abnormal-exit loss to about one second")
    func defaultFlushCadence() async throws {
        let url = temporaryDatabaseURL()
        let persistence = try ChatPersistence(database: ChatDatabase(url: url))
        let interval = await persistence.flushInterval
        #expect(interval == .seconds(1))
        try cleanup(url: url)
    }

    @Test("Captured chat lines are flushed with channel + player intact")
    func capturedLinesArePersisted() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .milliseconds(20))
        await persistence.attach(to: store)

        await store.append(channel: "gossip", player: "Wolf", message: "@Whello there")
        await store.append(channel: "tell", player: "Friend", message: "psst")
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let rows = try database.mostRecent(limit: 10)
        #expect(rows.map(\.channel) == ["gossip", "tell"])
        #expect(rows.map(\.player) == ["Wolf", "Friend"])
        #expect(rows[0].text.contains("hello there"))

        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("periodic flush drains all mutations published before its checkpoint")
    func periodicFlushDrainsCheckpoint() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .milliseconds(20))
        await persistence.attach(to: store)

        await store.append(channel: "clantalk", player: "Friend", message: "persist me")
        try await Task.sleep(for: .milliseconds(80))

        #expect(try database.mostRecent(limit: 10).map(\.text) == ["persist me"])
        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("typed sources and timestamp policy persist; omit-log lines do not")
    func typedSourcePersistence() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .milliseconds(20))
        await persistence.attach(to: store)
        await store.append(
            source: .nonChannel(.globalQuest),
            message: "Global Quest: starts now",
            showsTimestamp: false
        )
        await store.append(
            source: .plugin("Q/A"), message: "temporary", shouldPersist: false
        )
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let rows = try database.mostRecent(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].sourceKind == "nonchannel")
        #expect(rows[0].sourceName == NonChannelKind.globalQuest.rawValue)
        #expect(!rows[0].showsTimestamp)
        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("source and all-history clears remove queued and persisted rows in order")
    func durableClear() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .seconds(60))
        await persistence.attach(to: store)

        await store.append(source: .nonChannel(.info), message: "INFO: old")
        await store.append(channel: "tell", player: "Friend", message: "keep")
        await store.clear(source: .nonChannel(.info))
        await store.append(source: .nonChannel(.info), message: "INFO: new")
        await persistence.flushNow()

        #expect(try database.mostRecent(limit: 10).map(\.text) == ["keep", "INFO: new"])
        await store.clear(source: nil)
        await persistence.flushNow()
        #expect(try database.count() == 0)

        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("detach() flushes buffered writes (graceful shutdown)")
    func detachFlushesBuffer() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .seconds(60))
        await persistence.attach(to: store)

        for index in 0..<5 {
            await store.append(channel: "gossip", player: "P", message: "line-\(index)")
        }
        await persistence.detach()

        let rows = try database.mostRecent(limit: 10)
        #expect(rows.map(\.text) == (0..<5).map { "line-\($0)" })
        try cleanup(url: url)
    }

    @Test("flushNow drains published mutations without a scheduler delay")
    func immediateFlushDrainsMutations() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .seconds(60))
        await persistence.attach(to: store)

        await store.append(channel: "claninfo", player: "", message: "last line before quit")
        let result = await persistence.flushNow()

        #expect(try database.mostRecent(limit: 10).map(\.text) == ["last line before quit"])
        #expect(result.written == 1)
        #expect(result.pending == 0)
        #expect(result.errorDescription == nil)
        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("attaching persistence to a fresh Channels store does not hydrate history")
    func freshSessionStartsEmpty() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let previousStore = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .seconds(60))
        await persistence.attach(to: previousStore)
        await previousStore.append(channel: "clantalk", player: "Wolf", message: "old session")
        await persistence.flushNow()
        await persistence.detach()

        let freshStore = ChatStore()
        await persistence.attach(to: freshStore)

        #expect(await freshStore.snapshot().isEmpty)
        #expect(try database.mostRecent(limit: 10).map(\.text) == ["old session"])

        await freshStore.append(channel: "clantalk", player: "Wolf", message: "new session")
        await persistence.flushNow()
        #expect(await freshStore.snapshot().map(\.line.text) == ["new session"])
        #expect(try database.mostRecent(limit: 10).map(\.text) == ["old session", "new session"])

        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("recovery restore keeps styled runs and never re-persists")
    func restoreRoundTripWithoutReseeding() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .milliseconds(20))
        await persistence.attach(to: store)

        // @-coded message → styled runs at capture time.
        await store.append(channel: "gossip", player: "Wolf", message: "@Rred@w then white")
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()
        await persistence.detach()
        let persistedCount = try database.count()
        #expect(persistedCount == 1)

        // Interrupted-session recovery: seed from the tail BEFORE attaching.
        let restoredStore = ChatStore()
        let tail = try await persistence.loadTail(limit: 500)
        for row in tail {
            let line = try row.toLine()
            await restoredStore.restore(
                timestamp: row.timestamp, channel: row.channel, player: row.player, line: line
            )
        }
        await persistence.attach(to: restoredStore)
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        // The restored line is in the window's backlog, styled…
        let snapshot = await restoredStore.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].channel == "gossip")
        #expect(snapshot[0].player == "Wolf")
        #expect(!snapshot[0].line.runs.isEmpty)
        // …and was NOT written to the DB a second time.
        #expect(try database.count() == persistedCount)

        // A line captured after the restore persists normally.
        await restoredStore.append(channel: "tell", player: "F", message: "new session")
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()
        #expect(try database.count() == persistedCount + 1)

        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("loadTail returns the most recent lines oldest-first")
    func loadTailOrdering() async throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        let store = ChatStore()
        let persistence = ChatPersistence(database: database, flushInterval: .milliseconds(20))
        await persistence.attach(to: store)
        for text in ["one", "two", "three"] {
            await store.append(channel: "gossip", player: "P", message: text)
        }
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let restored = try await persistence.loadTail(limit: 2)
        #expect(restored.map(\.text) == ["two", "three"])

        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("search matches text with AND semantics; channel narrows it")
    func searchWithChannelFilter() throws {
        let url = temporaryDatabaseURL()
        let database = try ChatDatabase(url: url)
        try database.insertBatch([
            PersistedChatLine(
                timestamp: Date(), channel: "gossip", player: "A", text: "the wolf howls"
            ),
            PersistedChatLine(
                timestamp: Date(), channel: "tell", player: "B", text: "a wolf appears"
            ),
            PersistedChatLine(
                timestamp: Date(), channel: "gossip", player: "C", text: "nothing here"
            )
        ])

        #expect(try database.search("wolf").count == 2)
        let narrowed = try database.search("wolf", channel: "tell")
        #expect(narrowed.map(\.player) == ["B"])
        try cleanup(url: url)
    }

    @Test("rows older than the retention window are pruned on open")
    func retentionPrunesOldRows() throws {
        let url = temporaryDatabaseURL()
        // Seed with retention disabled: one ancient row, one fresh.
        let seeded = try ChatDatabase(url: url, retentionDays: nil)
        try seeded.insertBatch([
            PersistedChatLine(
                timestamp: Date(timeIntervalSinceNow: -90 * 86400),
                channel: "gossip",
                player: "Old",
                text: "ancient history"
            ),
            PersistedChatLine(
                timestamp: Date(), channel: "gossip", player: "New", text: "just now"
            )
        ])
        #expect(try seeded.count() == 2)

        // Re-open with the default 30-day retention: the ancient row goes.
        let reopened = try ChatDatabase(url: url)
        #expect(try reopened.count() == 1)
        #expect(try reopened.mostRecent(limit: 10).map(\.player) == ["New"])
        try cleanup(url: url)
    }
}

// MARK: - Helpers

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "proteles-chat-persistence-test-\(UUID().uuidString).sqlite"
    )
}

private func cleanup(url: URL) throws {
    let fileManager = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        let candidate = URL(fileURLWithPath: url.path + suffix)
        try? fileManager.removeItem(at: candidate)
    }
}

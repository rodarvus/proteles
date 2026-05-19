import Foundation
@testable import MudCore
import Testing

@Suite("ScrollbackPersistence", .serialized)
struct ScrollbackPersistenceTests {
    @Test("Appended lines are flushed to the database")
    func appendedLinesArePersisted() async throws {
        let url = temporaryDatabaseURL()
        let database = try ScrollbackDatabase(url: url)
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(
            database: database,
            flushInterval: .milliseconds(20)
        )
        await persistence.attach(to: store)

        await store.append(text: "first")
        await store.append(text: "second")

        // Give the periodic flusher time to run.
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let lines = try database.mostRecent(limit: 10)
        #expect(lines.map(\.text) == ["first", "second"])

        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("detach() flushes buffered writes (graceful shutdown)")
    func detachFlushesBuffer() async throws {
        let url = temporaryDatabaseURL()
        let database = try ScrollbackDatabase(url: url)
        let store = ScrollbackStore()
        // A long flush interval ensures the buffer holds the writes
        // until detach() forces a flush.
        let persistence = ScrollbackPersistence(
            database: database,
            flushInterval: .seconds(60)
        )
        await persistence.attach(to: store)

        for index in 0..<5 {
            await store.append(text: "line-\(index)")
        }
        // Give the subscriber Task time to enqueue before detach.
        try await Task.sleep(for: .milliseconds(50))

        await persistence.detach()

        let lines = try database.mostRecent(limit: 10)
        #expect(lines.map(\.text) == (0..<5).map { "line-\($0)" })
        try cleanup(url: url)
    }

    @Test("Search round-trips a persisted line")
    func searchFindsAPersistedLine() async throws {
        let url = temporaryDatabaseURL()
        let database = try ScrollbackDatabase(url: url)
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(
            database: database,
            flushInterval: .milliseconds(20)
        )
        await persistence.attach(to: store)

        await store.append(text: "the misty wolf approaches.")
        await store.append(text: "an ogre roars.")
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let hits = try await persistence.search("wolf")
        #expect(hits.map(\.text) == ["the misty wolf approaches."])

        await persistence.detach()
        try cleanup(url: url)
    }

    @Test("Styled runs survive a store → persistence → DB → restore round-trip")
    func styledRunsSurviveRoundTrip() async throws {
        let url = temporaryDatabaseURL()
        let database = try ScrollbackDatabase(url: url)
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(
            database: database,
            flushInterval: .milliseconds(20)
        )
        await persistence.attach(to: store)

        let bold = StyleAttributes(bold: true)
        await store.append(
            text: "you hit the troll for 42 damage.",
            runs: [
                StyledRun(utf16Range: 13..<18, style: bold)
            ]
        )
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let lines = try database.mostRecent(limit: 1)
        let restored = try lines[0].toLine()
        #expect(restored.text == "you hit the troll for 42 damage.")
        #expect(restored.runs == [StyledRun(utf16Range: 13..<18, style: bold)])

        await persistence.detach()
        try cleanup(url: url)
    }
}

// MARK: - Helpers

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "proteles-persistence-test-\(UUID().uuidString).sqlite"
    )
}

private func cleanup(url: URL) throws {
    let fileManager = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        let candidate = URL(fileURLWithPath: url.path + suffix)
        try? fileManager.removeItem(at: candidate)
    }
}

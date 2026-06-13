import Foundation
@testable import MudCore
import Testing

/// ``ScrollbackPersistence`` is now sidecar-only (#65 follow-up: the SQLite/FTS
/// index was removed). These cover the store → sidecar flow, graceful-shutdown
/// flushing, styled-run round-trips, and the resume tail.
@Suite("ScrollbackPersistence", .serialized)
struct ScrollbackPersistenceTests {
    @Test("Appended lines are flushed to the sidecar")
    func appendedLinesArePersisted() async throws {
        let url = temporarySidecarURL()
        defer { try? cleanup(url: url) }
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(
            sidecarURL: url,
            flushInterval: .milliseconds(20)
        )
        await persistence.attach(to: store)

        await store.append(text: "first")
        await store.append(text: "second")

        // Give the periodic flusher time to run.
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let entries = ScrollbackSidecar(url: url).tail(limit: 10)
        #expect(entries.map(\.text) == ["first", "second"])

        await persistence.detach()
    }

    @Test("detach() flushes buffered writes (graceful shutdown)")
    func detachFlushesBuffer() async throws {
        let url = temporarySidecarURL()
        defer { try? cleanup(url: url) }
        let store = ScrollbackStore()
        // A long flush interval ensures the buffer holds the writes until
        // detach() forces a flush.
        let persistence = ScrollbackPersistence(
            sidecarURL: url,
            flushInterval: .seconds(60)
        )
        await persistence.attach(to: store)

        for index in 0..<5 {
            await store.append(text: "line-\(index)")
        }
        // Give the subscriber Task time to enqueue before detach.
        try await Task.sleep(for: .milliseconds(50))

        await persistence.detach()

        let entries = ScrollbackSidecar(url: url).tail(limit: 10)
        #expect(entries.map(\.text) == (0..<5).map { "line-\($0)" })
    }

    @Test("Styled runs survive a store → persistence → sidecar → restore round-trip")
    func styledRunsSurviveRoundTrip() async throws {
        let url = temporarySidecarURL()
        defer { try? cleanup(url: url) }
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(
            sidecarURL: url,
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

        let restored = await persistence.loadTail(limit: 1)
        #expect(restored.count == 1)
        #expect(restored[0].text == "you hit the troll for 42 damage.")
        #expect(restored[0].runs == [StyledRun(utf16Range: 13..<18, style: bold)])

        await persistence.detach()
    }

    @Test("loadTail returns the most recent lines oldest-first, read-only (#42)")
    func loadTailRestoresRecentLines() async throws {
        let url = temporarySidecarURL()
        defer { try? cleanup(url: url) }
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(sidecarURL: url, flushInterval: .milliseconds(20))
        await persistence.attach(to: store)
        for text in ["one", "two", "three"] {
            await store.append(text: text)
        }
        try await Task.sleep(for: .milliseconds(80))
        await persistence.flushNow()

        let restored = await persistence.loadTail(limit: 2)
        #expect(restored.map(\.text) == ["two", "three"]) // last two, oldest-first

        // Read-only: the sidecar still holds exactly the three originals
        // (restoring must not re-persist).
        #expect(ScrollbackSidecar(url: url).tail(limit: 10).count == 3)

        await persistence.detach()
    }
}

// MARK: - Helpers

private func temporarySidecarURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "proteles-persistence-test-\(UUID().uuidString).jsonl"
    )
}

private func cleanup(url: URL) throws {
    try? FileManager.default.removeItem(at: url)
}

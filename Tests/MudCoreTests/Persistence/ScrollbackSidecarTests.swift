import Foundation
@testable import MudCore
import Testing

/// The #66 persistence redesign: sidecar ring mechanics, the hot/cold
/// two-cadence flow, the resume tail reading the sidecar, and the crash
/// reconciliation that re-indexes flushed-but-unindexed lines on launch.
@Suite("Scrollback sidecar + cold-path indexing (#66)", .serialized)
struct ScrollbackSidecarTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString).\(ext)")
    }

    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    @Test("appends assign monotonic seqs; reopen continues; torn tail tolerated")
    func sidecarBasics() throws {
        let url = tempURL("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let sidecar = ScrollbackSidecar(url: url, targetLines: 100)
        let first = try sidecar.append([line("one"), line("two")])
        #expect(first.map(\.seq) == [0, 1])

        // Reopen continues the sequence (a relaunch must not restart at 0 —
        // the index cursor compares across launches).
        let reopened = ScrollbackSidecar(url: url, targetLines: 100)
        let second = try reopened.append([line("three")])
        #expect(second.map(\.seq) == [2])
        #expect(reopened.tail(limit: 10).map(\.text) == ["one", "two", "three"])

        // A torn trailing line (mid-write crash) is skipped, not fatal.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\": 99, \"tex".utf8))
        try handle.close()
        let afterTear = ScrollbackSidecar(url: url, targetLines: 100)
        #expect(afterTear.tail(limit: 10).map(\.text) == ["one", "two", "three"])
    }

    @Test("rotation keeps the newest targetLines and the sequence intact")
    func sidecarRotation() throws {
        let url = tempURL("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let sidecar = ScrollbackSidecar(url: url, targetLines: 10)
        for index in 0..<35 { // crosses the 2x rotation threshold repeatedly
            _ = try sidecar.append([line("line-\(index)")])
        }
        let tail = sidecar.tail(limit: 100)
        #expect(tail.count <= 20) // never more than 2x target on disk
        #expect(tail.last?.text == "line-34")
        #expect(tail.last?.seq == 34) // seqs survive rotation
        // The newest 10 are always present.
        #expect(tail.suffix(10).map(\.text) == (25..<35).map { "line-\($0)" })
    }

    @Test("hot path lands in the sidecar; cold path indexes in one batch on demand")
    func twoCadenceFlow() async throws {
        let dbURL = tempURL("sqlite")
        let scURL = tempURL("jsonl")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: dbURL.path + suffix)
                )
            }
            try? FileManager.default.removeItem(at: scURL)
        }
        let database = try ScrollbackDatabase(url: dbURL)
        let store = ScrollbackStore()
        // A practically-never index cadence: only flushNow/detach index.
        let persistence = ScrollbackPersistence(
            database: database,
            sidecarURL: scURL,
            flushInterval: .milliseconds(20),
            indexInterval: .seconds(3600)
        )
        await persistence.attach(to: store)

        await store.append(text: "the misty wolf approaches.")
        await store.append(text: "an ogre roars.")
        try await Task.sleep(for: .milliseconds(120))

        // Hot path current, cold path not yet run.
        let reader = ScrollbackSidecar(url: scURL)
        #expect(reader.tail(limit: 10).map(\.text)
            == ["the misty wolf approaches.", "an ogre roars."])
        #expect(try database.count() == 0)
        // The resume tail reads the sidecar, not the (stale) index.
        let restored = try await persistence.loadTail(limit: 10)
        #expect(restored.map(\.text) == ["the misty wolf approaches.", "an ogre roars."])

        // flushNow drains the cold path in one transaction + advances cursor.
        await persistence.flushNow()
        #expect(try database.count() == 2)
        #expect(try database.indexedThroughSeq() == 1)
        #expect(try await persistence.search("wolf").map(\.text)
            == ["the misty wolf approaches."])

        await persistence.detach()
    }

    @Test("crash recovery: flushed-but-unindexed sidecar lines reconcile on attach")
    func crashReconciliation() async throws {
        let dbURL = tempURL("sqlite")
        let scURL = tempURL("jsonl")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: dbURL.path + suffix)
                )
            }
            try? FileManager.default.removeItem(at: scURL)
        }

        // "Session one" crashes: sidecar has lines, index never ran (no
        // detach — the actor is just dropped, like a SIGKILL).
        do {
            let database = try ScrollbackDatabase(url: dbURL)
            let store = ScrollbackStore()
            let persistence = ScrollbackPersistence(
                database: database,
                sidecarURL: scURL,
                flushInterval: .milliseconds(20),
                indexInterval: .seconds(3600)
            )
            await persistence.attach(to: store)
            await store.append(text: "before the crash")
            await store.append(text: "also before the crash")
            try await Task.sleep(for: .milliseconds(120))
            #expect(try database.count() == 0) // crash-window state
            // No detach: the actor is simply dropped at scope end (its tasks
            // hold weak self), so nothing flushes — a SIGKILL in miniature.
            _ = persistence // silence "unused" while making the drop explicit
        }

        // "Session two": attach reconciles the orphaned sidecar entries.
        let database = try ScrollbackDatabase(url: dbURL)
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(
            database: database,
            sidecarURL: scURL,
            flushInterval: .milliseconds(20),
            indexInterval: .seconds(3600)
        )
        await persistence.attach(to: store)
        #expect(try database.count() == 2)
        #expect(try database.indexedThroughSeq() == 1)
        #expect(try await persistence.search("crash").count == 2)

        // And reconciliation is idempotent: re-attaching adds nothing.
        await persistence.attach(to: store)
        #expect(try database.count() == 2)
        await persistence.detach()
    }
}

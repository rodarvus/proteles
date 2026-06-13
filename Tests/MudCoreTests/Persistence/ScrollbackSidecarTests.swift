import Foundation
@testable import MudCore
import Testing

/// The JSONL sidecar ring (#66): append/seq mechanics, reopen continuity,
/// torn-tail tolerance, and rotation. (The cold-path SQLite index and its
/// crash reconciliation were removed in the #65 follow-up — see
/// ``ScrollbackPersistence``.)
@Suite("Scrollback sidecar ring (#66)", .serialized)
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

        // Reopen continues the sequence (a relaunch must not restart at 0).
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

    @Test("the resume tail reads the sidecar, current to the last flush")
    func resumeTailReadsSidecar() async throws {
        let url = tempURL("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScrollbackStore()
        let persistence = ScrollbackPersistence(
            sidecarURL: url,
            flushInterval: .milliseconds(20)
        )
        await persistence.attach(to: store)

        await store.append(text: "the misty wolf approaches.")
        await store.append(text: "an ogre roars.")
        try await Task.sleep(for: .milliseconds(120))

        let restored = await persistence.loadTail(limit: 10)
        #expect(restored.map(\.text) == ["the misty wolf approaches.", "an ogre roars."])

        await persistence.detach()
    }
}

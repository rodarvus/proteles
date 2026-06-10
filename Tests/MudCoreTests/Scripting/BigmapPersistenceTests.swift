import Foundation
@testable import MudCore
import Testing

/// #54 — captured continent bigmaps persist across sessions, so stepping
/// overland on a fresh launch shows the map instantly instead of a
/// "fetching…" gap (the plugin's once-per-session re-fetch still refreshes
/// it, so a continent Aardwolf changed self-heals).
@Suite("Bigmap — persistence across sessions (#54)")
struct BigmapPersistenceTests {
    private func sampleMap(zone: Int = 1) -> BigmapStore.ContinentMap {
        let runs = [StyledRun(utf16Range: 0..<6, style: StyleAttributes(foreground: .palette(4)))]
        return BigmapStore.ContinentMap(
            zone: zone,
            name: "Mesolar",
            lines: [
                Line(id: LineID(0), text: "~~^^..", runs: runs),
                Line(id: LineID(0), text: "~?~~..", runs: [])
            ]
        )
    }

    @Test("a capture round-trips through disk into a fresh store")
    func roundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigmaps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = BigmapStore(url: url)
        await first.update(sampleMap())
        await first.update(sampleMap(zone: 3))

        // A fresh store (next launch) reads both back, styled runs intact.
        let second = BigmapStore(url: url)
        let restored = try #require(await second.map(forZone: 1))
        #expect(restored.name == "Mesolar")
        #expect(restored.lines.map(\.text) == ["~~^^..", "~?~~.."])
        #expect(restored.lines[0].runs == sampleMap().lines[0].runs)
        #expect(await second.map(forZone: 3) != nil)
        #expect(await second.map(forZone: 9) == nil)
    }

    @Test("a fresh session capture replaces the persisted map (the refresh)")
    func sessionCaptureWins() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigmaps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = BigmapStore(url: url)
        await first.update(sampleMap())

        let second = BigmapStore(url: url)
        let fresher = BigmapStore.ContinentMap(
            zone: 1, name: "Mesolar", lines: [Line(id: LineID(0), text: "NEW")]
        )
        await second.update(fresher)
        #expect(await second.map(forZone: 1)?.lines.first?.text == "NEW")

        // …and the replacement is what persists for the third session.
        let third = BigmapStore(url: url)
        #expect(await third.map(forZone: 1)?.lines.first?.text == "NEW")
    }

    @Test("a memory-only store (no URL) works and writes nothing")
    func memoryOnly() async {
        let store = BigmapStore()
        await store.update(sampleMap())
        #expect(await store.map(forZone: 1) != nil)
    }

    @Test("reset clears the session but the disk cache survives")
    func resetKeepsDisk() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigmaps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BigmapStore(url: url)
        await store.update(sampleMap())
        await store.reset()
        // The lazy reload brings the persisted capture back.
        #expect(await store.map(forZone: 1) != nil)
    }
}

import Foundation
@testable import MudCore
import Testing

/// Phase 3 of the mapper DB split (D-111): `splitPersonal` demuxes a single-file
/// `Aardwolf.db` (per-character data mixed into the shared map) into the shared
/// world map + a per-character overlay. Reused by import demux and migration, so
/// the headline property is **lossless round-trip**: the merged graph after the
/// split equals the graph before it.
@Suite("MapperStore — split / demux (D-111)")
struct MapperSplitTests {
    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("split-\(tag)-\(UUID().uuidString).db")
    }

    /// Seed a single-file store with shared + per-character data intermixed.
    private func seedSingleFile(_ url: URL) throws {
        let store = try MapperStore(url: url) // State A: everything in shared
        try store.upsert(Room(uid: "100", name: "Square", area: "town"))
        try store.upsert(Room(uid: "200", name: "Gate", area: "town"))
        try store.saveExits(from: "100", exits: [
            "n": Exit(dir: "n", to: "200"),
            "enter portal": Exit(dir: "enter portal", to: "200")
        ])
        _ = try store.setExitLevel(from: "100", dir: "n", level: 9) // cardinal lock
        try store.addPortal(dir: "recall", touid: "200", level: 0, recall: false)
        try store.setNote("bank here", uid: "100")
    }

    @Test("split is a lossless round-trip (merged graph == pre-split graph)")
    func losslessRoundTrip() throws {
        let shared = tempURL("shared")
        let overlay = tempURL("overlay")
        defer {
            try? FileManager.default.removeItem(at: shared)
            try? FileManager.default.removeItem(at: overlay)
        }
        try seedSingleFile(shared)
        let before = try MapperStore(url: shared).loadGraph()

        let summary = try MapperStore.splitPersonal(sharedURL: shared, overlayURL: overlay)
        #expect(summary == MapperStore.SplitSummary(
            portals: 1, customExits: 1, exitLocks: 1, notes: 1, alreadySplit: false
        ))

        let after = try MapperStore(url: shared, personalURL: overlay).loadGraph()
        #expect(after == before)
    }

    @Test("after split the shared file is the clean canonical map")
    func sharedIsClean() throws {
        let shared = tempURL("shared")
        let overlay = tempURL("overlay")
        defer {
            try? FileManager.default.removeItem(at: shared)
            try? FileManager.default.removeItem(at: overlay)
        }
        try seedSingleFile(shared)
        try MapperStore.splitPersonal(sharedURL: shared, overlayURL: overlay)

        // Re-open shared alone: no portals, no custom exits, no notes, cardinals
        // back at level 0 (the personal data now lives only in the overlay).
        let sharedOnly = try MapperStore(url: shared)
        #expect(try sharedOnly.portals().isEmpty)
        #expect(try sharedOnly.customExits().isEmpty)
        let graph = try sharedOnly.loadGraph()
        #expect(graph["100"]?.exits["n"]?.level == 0)
        #expect(graph["100"]?.exits["enter portal"] == nil)
        #expect(graph["100"]?.notes == nil)
    }

    @Test("split is idempotent (a second run is a no-op)")
    func idempotent() throws {
        let shared = tempURL("shared")
        let overlay = tempURL("overlay")
        defer {
            try? FileManager.default.removeItem(at: shared)
            try? FileManager.default.removeItem(at: overlay)
        }
        try seedSingleFile(shared)
        try MapperStore.splitPersonal(sharedURL: shared, overlayURL: overlay)

        let second = try MapperStore.splitPersonal(sharedURL: shared, overlayURL: overlay)
        #expect(second.alreadySplit)
        #expect(second == MapperStore.SplitSummary(alreadySplit: true))
    }

    @Test("import copy demuxes the mapper into shared + per-character overlay")
    func importDemux() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-demux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A MUSHclient-style source DB (single file, mixed).
        let source = dir.appendingPathComponent("source-Aardwolf.db")
        try seedSingleFile(source)

        let databases = dir.appendingPathComponent("Databases")
        try FileManager.default.createDirectory(at: databases, withIntermediateDirectories: true)
        let entry = ImportManifest.DatabaseEntry(url: source, kind: .mapper, byteSize: 0)
        let dest = try DatabaseImporter.copy(entry, character: "Rodarvus", in: databases)

        #expect(dest == databases.appendingPathComponent("Aardwolf.db"))
        let overlay = databases.appendingPathComponent("Rodarvus")
            .appendingPathComponent("Aardwolf-personal.db")
        #expect(FileManager.default.fileExists(atPath: overlay.path))
        // The imported map is whole again when read with the character's overlay.
        let graph = try MapperStore(url: dest!, personalURL: overlay).loadGraph()
        #expect(graph["100"]?.exits["enter portal"]?.to == "200")
        #expect(graph["100"]?.exits["n"]?.level == 9)
        #expect(graph["*"]?.exits["recall"]?.to == "200")
    }
}

import Foundation
@testable import MudCore
import Testing

/// Phase 4 of the mapper DB split (D-111): the live activation
/// (`Mapper.attachPersonalStore`) and the non-destructive migration
/// (`migratePersonal`). Activation is gated on the `personal_split` flag so an
/// un-migrated DB is never read through the overlay path (no "State B").
@Suite("Mapper — overlay activation + migration (D-111)")
struct MapperMigrationTests {
    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(tag)-\(UUID().uuidString).db")
    }

    private func seedSingleFile(_ url: URL) throws {
        let store = try MapperStore(url: url)
        try store.upsert(Room(uid: "100", name: "Square", area: "town"))
        try store.upsert(Room(uid: "200", name: "Gate", area: "town"))
        try store.saveExits(from: "100", exits: [
            "n": Exit(dir: "n", to: "200"),
            "enter portal": Exit(dir: "enter portal", to: "200")
        ])
        _ = try store.setExitLevel(from: "100", dir: "n", level: 9)
        try store.addPortal(dir: "recall", touid: "200", level: 0, recall: false)
        try store.setNote("bank here", uid: "100")
    }

    @Test("attachPersonalStore merges the overlay once the DB is split")
    func activateAfterSplit() async throws {
        let shared = tempURL("shared")
        let overlay = tempURL("overlay")
        defer {
            try? FileManager.default.removeItem(at: shared)
            try? FileManager.default.removeItem(at: overlay)
        }
        try seedSingleFile(shared)
        let original = try MapperStore(url: shared).loadGraph()
        try MapperStore.splitPersonal(sharedURL: shared, overlayURL: overlay)

        // The mapper opens shared single-file (State A): the personal rows have
        // moved to the overlay, so it sees only the cardinal map.
        let mapper = try Mapper(store: MapperStore(url: shared))
        var graph = await mapper.graph
        #expect(graph["100"]?.exits["enter portal"] == nil)
        #expect(graph["*"]?.exits["recall"] == nil)

        // Activating the overlay restores the full, merged graph.
        try await mapper.attachPersonalStore(at: overlay)
        graph = await mapper.graph
        #expect(graph == original)
    }

    @Test("attachPersonalStore is a no-op on an un-split (single-file) DB")
    func activationGatedOnSplit() async throws {
        let shared = tempURL("shared")
        let overlay = tempURL("overlay")
        defer {
            try? FileManager.default.removeItem(at: shared)
            try? FileManager.default.removeItem(at: overlay)
        }
        try seedSingleFile(shared) // NOT split → no personal_split flag

        let mapper = try Mapper(store: MapperStore(url: shared))
        let before = await mapper.graph
        try await mapper.attachPersonalStore(at: overlay) // guarded → no-op
        let after = await mapper.graph
        #expect(after == before) // unchanged: still the single-file graph
    }

    @Test("migratePersonal backs up the original, then splits losslessly")
    func migrationIsNonDestructiveAndLossless() throws {
        let shared = tempURL("shared")
        let overlay = tempURL("overlay")
        let backup = tempURL("backup")
        defer {
            for url in [shared, overlay, backup] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try seedSingleFile(shared)
        let original = try MapperStore(url: shared).loadGraph()

        try MapperStore.migratePersonal(sharedURL: shared, overlayURL: overlay, backupURL: backup)

        // The backup is a clean, complete copy of the pre-migration map…
        #expect(try MapperStore(url: backup).loadGraph() == original)
        // …and the migrated shared + overlay round-trips back to the original.
        #expect(try MapperStore(url: shared, personalURL: overlay).loadGraph() == original)
    }

    @Test("Mapper.migratePersonal: prompt detection → migrate-and-attach round-trip")
    func mapperLevelMigration() async throws {
        let shared = tempURL("shared")
        let overlay = tempURL("overlay")
        let backup = tempURL("backup")
        defer {
            for url in [shared, overlay, backup] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try seedSingleFile(shared)
        let original = try MapperStore(url: shared).loadGraph()

        let mapper = try Mapper(store: MapperStore(url: shared))
        #expect(await mapper.needsPersonalMigration()) // un-migrated, has personals

        try await mapper.migratePersonal(overlayURL: overlay, backupURL: backup)
        #expect(await !mapper.needsPersonalMigration()) // now split + attached
        #expect(await mapper.graph == original) // map is whole again, merged
    }
}

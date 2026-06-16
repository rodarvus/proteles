import Foundation
@testable import MudCore
import Testing

/// The per-character overlay split (D-111): per-character data (portals, custom
/// exits, exit-locks, notes) lives in `Aardwolf-personal.db` and must NOT bleed
/// across characters, while the shared map (rooms, cardinal exits) is common.
/// These exercise State C (overlay attached) — the merge, the routing, and the
/// isolation property that is the whole point of the feature.
@Suite("MapperStore — per-character overlay (D-111)")
struct MapperStorePersonalTests {
    /// A shared map DB plus two character overlays over it, all temp files.
    private struct Fixture {
        let urls: [URL]
        let s1: MapperStore // character 1
        let s2: MapperStore // character 2 (same shared map)
    }

    private func makeStores() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
        let shared = dir.appendingPathComponent("shared-\(UUID().uuidString).db")
        let p1 = dir.appendingPathComponent("p1-\(UUID().uuidString).db")
        let p2 = dir.appendingPathComponent("p2-\(UUID().uuidString).db")
        let s1 = try MapperStore(url: shared, personalURL: p1)
        let s2 = try MapperStore(url: shared, personalURL: p2)
        // A two-room shared world both characters share.
        try s1.upsert(Room(uid: "100", name: "Square", area: "town"))
        try s1.upsert(Room(uid: "200", name: "Gate", area: "town"))
        try s1.saveExits(from: "100", exits: ["n": Exit(dir: "n", to: "200")])
        return Fixture(urls: [shared, p1, p2], s1: s1, s2: s2)
    }

    private func cleanup(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("a portal is visible to its own character but not another")
    func portalIsolated() throws {
        let fix = try makeStores()
        defer { cleanup(fix.urls) }
        try fix.s1.addPortal(dir: "recall home", touid: "200", level: 0, recall: false)

        #expect(try fix.s1.loadGraph()["*"]?.exits["recall home"]?.to == "200")
        #expect(try fix.s2.loadGraph()["*"]?.exits["recall home"] == nil)
        // The shared file holds the `*` sentinel room but never the portal exit.
        #expect(try fix.s1.portals().count == 1)
        #expect(try fix.s2.portals().isEmpty)
    }

    @Test("a custom exit is per-character; the shared cardinal exit is common")
    func customExitIsolated() throws {
        let fix = try makeStores()
        defer { cleanup(fix.urls) }
        try fix.s1.addCustomExit(dir: "enter portal", from: "100", to: "200", level: 0)

        let g1 = try fix.s1.loadGraph()
        let g2 = try fix.s2.loadGraph()
        // Both characters share the cardinal exit (shared map)…
        #expect(g1["100"]?.exits["n"]?.to == "200")
        #expect(g2["100"]?.exits["n"]?.to == "200")
        // …but only character 1 has the custom exit.
        #expect(g1["100"]?.exits["enter portal"]?.to == "200")
        #expect(g2["100"]?.exits["enter portal"] == nil)
        #expect(try fix.s1.customExits().map(\.dir) == ["enter portal"])
        #expect(try fix.s2.customExits().isEmpty)
    }

    @Test("a cardinal exit-lock overlays without mutating the shared row")
    func exitLockIsOverlay() throws {
        let fix = try makeStores()
        defer { cleanup(fix.urls) }
        #expect(try fix.s1.setExitLevel(from: "100", dir: "n", level: 5))

        // Character 1 sees the lock; character 2 sees the canonical level 0.
        #expect(try fix.s1.loadGraph()["100"]?.exits["n"]?.level == 5)
        #expect(try fix.s2.loadGraph()["100"]?.exits["n"]?.level == 0)
    }

    @Test("a room note is per-character")
    func noteIsolated() throws {
        let fix = try makeStores()
        defer { cleanup(fix.urls) }
        try fix.s1.setNote("bank here", uid: "100")

        #expect(try fix.s1.loadGraph()["100"]?.notes == "bank here")
        #expect(try fix.s2.loadGraph()["100"]?.notes == nil)
    }

    @Test("saveExits keeps the lock when the room is revisited (GMCP re-report)")
    func lockSurvivesSaveExits() throws {
        let fix = try makeStores()
        defer { cleanup(fix.urls) }
        _ = try fix.s1.setExitLevel(from: "100", dir: "n", level: 7)
        // GMCP re-reports the room: the merged in-memory exit carries level 7,
        // but saveExits must write the shared cardinal at 0 and leave the lock
        // in the overlay — so the lock survives.
        try fix.s1.saveExits(from: "100", exits: ["n": Exit(dir: "n", to: "200", level: 7)])

        #expect(try fix.s1.loadGraph()["100"]?.exits["n"]?.level == 7)
    }

    @Test("purgeRoom clears overlay rows too")
    func purgeRoomClearsOverlay() throws {
        let fix = try makeStores()
        defer { cleanup(fix.urls) }
        try fix.s1.addCustomExit(dir: "climb wall", from: "100", to: "200", level: 0)
        _ = try fix.s1.setExitLevel(from: "100", dir: "n", level: 3)
        try fix.s1.setNote("x", uid: "100")

        try fix.s1.purgeRoom(uid: "100")
        let graph = try fix.s1.loadGraph()
        #expect(graph["100"]?.exits["climb wall"] == nil)
        #expect(try fix.s1.customExits().isEmpty)
    }

    @Test("single-file mode (no overlay) behaves as before the split")
    func singleFileFallback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-\(UUID().uuidString).db")
        defer { cleanup([url]) }
        let store = try MapperStore(url: url) // personalURL nil
        #expect(!store.hasPersonalStore)
        try store.upsert(Room(uid: "1", name: "Here", area: "z"))
        try store.addPortal(dir: "recall", touid: "1", level: 0, recall: false)
        try store.addCustomExit(dir: "enter rift", from: "1", to: "1", level: 0)
        #expect(try store.portals().count == 1)
        #expect(try store.customExits().map(\.dir) == ["enter rift"])
        #expect(try store.loadGraph()["*"]?.exits["recall"]?.to == "1")
    }
}

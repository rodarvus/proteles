import Foundation
@testable import MudCore
import Testing

/// Phase 2 of the mapper DB split (D-111): a direct reader (Search-and-Destroy)
/// opens the shared `Aardwolf.db` via the sandboxed `sqlite3` global, and — when
/// a per-character overlay is registered — its unmodified `SELECT … FROM exits`
/// transparently sees the merged set (shared cardinals with overlay locks
/// applied, plus the overlay's portals and custom exits). The merge needs one
/// host-authorized `ATTACH`; the sandbox's blanket ATTACH ban still holds for
/// every other path.
@Suite("Mapper overlay merge for direct readers (D-111)")
struct MapperOverlayMergeTests {
    private struct Seed {
        let dir: URL
        let shared: URL
        let overlay: URL
    }

    private func seed() throws -> Seed {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shared = dir.appendingPathComponent("Aardwolf.db")
        let overlay = dir.appendingPathComponent("Aardwolf-personal.db")
        let store = try MapperStore(url: shared, personalURL: overlay)
        try store.upsert(Room(uid: "100", name: "Square", area: "town"))
        try store.upsert(Room(uid: "200", name: "Gate", area: "town"))
        try store.saveExits(from: "100", exits: ["n": Exit(dir: "n", to: "200")]) // shared cardinal
        try store.addCustomExit(dir: "enter portal", from: "100", to: "200", level: 0) // overlay
        try store.addPortal(dir: "recall", touid: "200", level: 0, recall: false) // overlay
        _ = try store.setExitLevel(from: "100", dir: "n", level: 9) // overlay exit_locks
        return Seed(dir: dir, shared: shared, overlay: overlay)
    }

    private func probeScript(_ shared: URL) -> String {
        """
        local db = sqlite3.open("\(shared.path)")
        local parts = {}
        for row in db:nrows("SELECT dir, level FROM exits WHERE fromuid = '100' ORDER BY dir") do
          parts[#parts + 1] = row.dir .. "=" .. tostring(row.level)
        end
        local portal = 0
        for row in db:nrows("SELECT count(*) AS n FROM exits WHERE fromuid = '*'") do
          portal = row.n
        end
        db:close()
        proteles.echo(table.concat(parts, ",") .. " | portals=" .. tostring(portal))
        """
    }

    @Test("with the overlay registered, a direct read sees the merged set")
    func mergedRead() async throws {
        let env = try seed()
        defer { try? FileManager.default.removeItem(at: env.dir) }

        let lua = try LuaRuntime()
        await lua.setSQLiteDirectory(env.dir.path)
        await lua.setMapperOverlay(sharedDBPath: env.shared.path, overlayPath: env.overlay.path)
        let effects = try await lua.run(probeScript(env.shared))
        // 'n' carries the overlay lock (9); the custom exit appears; portal seen.
        #expect(effects == [.echo("enter portal=0,n=9 | portals=1")])
    }

    @Test("without an overlay, the same read is the plain shared file")
    func unmergedRead() async throws {
        let env = try seed()
        defer { try? FileManager.default.removeItem(at: env.dir) }

        let lua = try LuaRuntime()
        await lua.setSQLiteDirectory(env.dir.path)
        // No setMapperOverlay → no ATTACH/view: shared has only the cardinal at
        // level 0 (the lock + custom + portal live in the un-attached overlay).
        let effects = try await lua.run(probeScript(env.shared))
        #expect(effects == [.echo("n=0 | portals=0")])
    }

    @Test("ATTACH of any non-overlay path is still denied")
    func attachStillDenied() async throws {
        let env = try seed()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let other = env.dir.appendingPathComponent("other.db")
        _ = try MapperStore(url: other) // a real, openable DB in the sandbox

        let lua = try LuaRuntime()
        await lua.setSQLiteDirectory(env.dir.path)
        await lua.setMapperOverlay(sharedDBPath: env.shared.path, overlayPath: env.overlay.path)
        // Opening the shared DB authorizes ONLY the overlay path; a hand-rolled
        // ATTACH of a different file must still be refused by the authorizer.
        let effects = try await lua.run("""
        local db = sqlite3.open("\(env.shared.path)")
        local code = db:exec("ATTACH DATABASE '\(other.path)' AS other")
        db:close()
        proteles.echo("attach_other_code=" .. tostring(code))
        """)
        // sqlite3.AUTH == 23 (the ban holds for non-overlay paths).
        #expect(effects == [.echo("attach_other_code=23")])
    }
}

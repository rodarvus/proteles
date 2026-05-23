import Foundation
@testable import MudCore
import Testing

@Suite("Search-and-Destroy — host (S1.2/S1.3)")
struct SearchAndDestroyHostTests {
    @Test("core.lua loads on the curated runtime; its functions are defined")
    func loadsCore() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // A handful of S&D's functions should now be callable globals.
        #expect(await host.functionExists("init_plugin"))
        #expect(await host.functionExists("migrate_database"))
        #expect(await host.functionExists("OnPluginBroadcast"))
    }

    @Test("S&D's DB-backed search runs end-to-end (lsqlite3 + curated bindings)")
    func searchRunsAgainstMapperDB() async throws {
        // A world-data dir with a mapper DB (Aardwolf.db) S&D will read.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try MapperStore(url: dir.appendingPathComponent("Aardwolf.db"))
        try store.upsert(Area(uid: "aylor", name: "Aylor"))
        try store.upsert(Room(uid: "100", name: "Town Square", area: "aylor"))
        try store.upsert(Room(uid: "101", name: "Market", area: "aylor"))

        let host = try SearchAndDestroyHost()
        await host.configure(directory: dir.path) // GetInfo(66) + sqlite root
        try await host.load()

        // Drive S&D's own search_rooms over the mapper DB it just located; it
        // *displays* the matches (no return value), so assert on the output.
        let effects = try await host.run("search_rooms('SELECT uid, name, area FROM rooms', nil)")
        let text = effects.compactMap { effect -> String? in
            switch effect {
            case .echo(let line): return line
            case .colourNote(let segs): return segs.map(\.text).joined()
            default: return nil
            }
        }.joined(separator: "\n")
        #expect(text.contains("Town Square"))
        #expect(text.contains("Market"))
    }

    @Test("xg_draw_window publishes a JSON model snapshot to the host (S2)")
    func publishesModel() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        #expect(await host.model == nil) // nothing published yet

        // A redraw publishes the current model, read from core.lua's own
        // scope — the default `current_activity` local is "init".
        try await host.run("xg_draw_window()")
        let json = try #require(await host.model)
        #expect(json.contains("\"activity\""))
        #expect(json.contains("init")) // the in-scope local value, not a global
        #expect(json.contains("\"targets\""))
        #expect(json.contains("\"target_count\""))
    }
}

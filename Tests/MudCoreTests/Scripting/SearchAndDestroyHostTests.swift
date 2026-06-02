import Foundation
@testable import MudCore
import Testing

@Suite("Search-and-Destroy — host (S1.2/S1.3)")
struct SearchAndDestroyHostTests {
    init() {
        SnDFixture.install()
    }

    @Test("core.lua loads on the curated runtime; its functions are defined")
    func loadsCore() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // A handful of S&D's functions should now be callable globals.
        #expect(await host.functionExists("init_plugin"))
        #expect(await host.functionExists("migrate_database"))
        #expect(await host.functionExists("OnPluginBroadcast"))
    }

    /// Regression: the post-navigation local scan (`xcp`/`go`/`nx` → smartscan/
    /// qw/con) only fires when S&D's arrival comparison `going_to_room ==
    /// current_room.rmid` succeeds. `current_room.rmid = gmcp("room.info").num`
    /// and `going_to_room = tostring(room_id)` (a string), so the comparison
    /// works only if `gmcp("room.info").num` is also a STRING — which it is in
    /// MUSHclient, where the Aardwolf GMCP handler recursively `stringify()`s
    /// every decoded value. Our host serialised nested number leaves as bare Lua
    /// numbers, so `gmcp("room.info").num` came back as `2339` (number) and the
    /// comparison `"2339" == 2339` was always false → no scan. Every leaf, at
    /// every access path, must be a string.
    @Test("gmcp leaves are stringified at every depth (the xcp/go/nx scan arrival check)")
    func gmcpLeavesAreStringsAtEveryDepth() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        _ = await host.applyGMCP(
            package: "room.info",
            json: #"{"num":2339,"zone":"light","exits":{"n":2343},"coord":{"x":30}}"#
        )
        // The nested scalar read the way S&D reads it: `gmcp("room.info").num`.
        #expect(await host.evaluate("type(gmcp('room.info').num)") == "string")
        #expect(await host.evaluate("gmcp('room.info').num") == "2339")
        // The literal arrival comparison S&D performs must now succeed.
        #expect(await host.evaluate("tostring(2339) == gmcp('room.info').num and 'yes' or 'no'") == "yes")
        // Deeper nesting (exits/coord) is stringified too — faithful to the
        // reference's recursive stringify().
        #expect(await host.evaluate("type(gmcp('room.info').exits.n)") == "string")
        #expect(await host.evaluate("type(gmcp('room.info').coord.x)") == "string")
    }

    @Test("Tell/ColourTell append; print/Note flush — one line per row")
    func tellNoteLineBuffering() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()

        func lines(_ effects: [ScriptEffect]) -> [String] {
            effects.compactMap { effect in
                if case .colourNote(let segs) = effect { return segs.map(\.text).joined() }
                return nil
            }
        }

        // A header row built from three ColourTells + a terminating print("")
        // must emit exactly ONE line, not four. (Pre-fix each ColourTell mapped
        // straight to a window line and print went to stdout, shattering rows.)
        let row = try await host.run(#"""
        ColourTell("#808080", "", "XCP  ")
        ColourTell("#808080", "", "Location")
        ColourTell("#808080", "", "  Notes")
        print("")
        """#)
        #expect(lines(row) == ["XCP  Location  Notes"])

        // Tell appends; Note flushes the whole accumulated line.
        let mixed = try await host.run(#"Tell("a"); Tell("b"); Note("c")"#)
        #expect(lines(mixed) == ["abc"])

        // A bare ColourNote (no pending Tell) is still its own single line.
        let solo = try await host.run(#"ColourNote("red", "", "hi")"#)
        #expect(lines(solo) == ["hi"])
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

        // The published JSON decodes into the typed model (S3).
        let model = try #require(SearchAndDestroyModel.decode(json))
        #expect(model.activity == "init")
        #expect(model.activityLabel == "—")
        #expect(model.targets.isEmpty)
        #expect(model.targetCount == 0)
    }

    @Test("the bridge publishes can-request-quest from quest_status_gmcp (qstat 0)")
    func publishesCanRequestQuest() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // The reference's off-quest "can request a new quest now" path sets
        // quest_target = {qstat = "0"} (+ next_quest_time = now).
        try await host.run(#"quest_status_gmcp({action = "status", status = "ready"})"#)
        try await host.run("xg_draw_window()")
        let json = try #require(await host.model)
        let model = try #require(SearchAndDestroyModel.decode(json))
        #expect(model.canRequestQuest)
        #expect(model.quest?.status == "0")
    }
    // (The on-quest qstat-2 path runs target_quest_mob → a DB-backed search;
    // the open-quest *field mapping* is covered by SearchAndDestroyModelTests'
    // decodesQuest, and this host test proves the bridge reads quest_target +
    // publishes end-to-end.)
}

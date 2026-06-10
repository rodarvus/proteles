import Foundation
@testable import MudCore
import Testing

/// S&D trigger firings must run under S&D's registered plugin context
/// (D-108). The generic `runScript` resets the ambient context to
/// `.default`, which blanked `GetInfo(66)` inside every firing — so
/// `area_index_line`'s very first statement,
/// `sqlite3.open(GetInfo(66) .. "/SnDdb.db")`, built a relative path the
/// sqlite sandbox denied and the handler died silently on every area row.
/// The area-range index stayed empty, and `build_room_targets` discarded
/// every SQL match at its `area_range_index[areaName]` gate — every
/// room-based campaign target showed `unknown: '<room>'`, forever (live
/// report, 2026-06-10; reproduced offline by replaying the recorded
/// session lines, then fixed).
///
/// This drives the real chain: the always-on `trg_area_index_start` arms
/// the line/end triggers, the line trigger's script opens SnDdb *at fire
/// time* via `GetInfo(66)` and inserts the area row. The insert landing in
/// the configured directory's SnDdb.db proves firings see S&D's context.
@Suite("S&D firings run in S&D's plugin context (D-108)")
struct SnDFiringContextTests {
    @Test("an area-index line fired through a trigger writes to the configured SnDdb")
    func areaIndexLineWrites() async throws {
        guard SnDFixture.install() else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = try SearchAndDestroyHost()
        await host.configure(directory: dir.path)
        try await host.load()

        // The fixture's bare load doesn't run S&D's table setup (that's a
        // connect-time step) — create the `area` table it inserts into,
        // matching S&D's live schema.
        _ = await host.evaluate("""
        (function()
          local ok, db = pcall(sqlite3.open, GetInfo(66) .. "SnDdb.db")
          if not ok or not db then return "no" end
          db:exec("CREATE TABLE IF NOT EXISTS area (name TEXT NOT NULL, key TEXT NOT NULL, "
            .. "minlvl INTEGER NOT NULL, maxlvl INTEGER NOT NULL, lock INTEGER NOT NULL, "
            .. "startRoom INTEGER, noquest TEXT, vidblain TEXT, userKey TEXT)")
          db:close()
          return "ok"
        end)()
        """)

        _ = await host.process("              [ Listing all areas in range 1 to 300 ]")
        _ = await host.process("   1    5       farm             Kimr's Farm                   ")
        _ = await host.process(String(repeating: "-", count: 63))

        // Read back through the same runtime (ambient context = configured).
        let count = await host.evaluate("""
        (function()
          local ok, db = pcall(sqlite3.open, GetInfo(66) .. "SnDdb.db")
          if not ok or not db then return "open-failed: " .. tostring(db) end
          local n = 0
          local okq, qerr = pcall(function()
            for row in db:nrows("SELECT name FROM area WHERE key = 'farm'") do n = n + 1 end
          end)
          db:close()
          if not okq then return "query-failed: " .. tostring(qerr) end
          return tostring(n)
        end)()
        """)
        #expect(count == "1", "area row missing — firing context lost GetInfo(66): \(count ?? "nil")")
    }
}

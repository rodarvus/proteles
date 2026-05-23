import Foundation
@testable import MudCore
import Testing

/// End-to-end: a plugin (via the sandboxed lsqlite3 `sqlite3` global) reads
/// the live mapper DB that the GRDB-backed ``MapperStore`` wrote — the exact
/// path Search-and-Destroy uses. Exercises the cross-connection read (two
/// SQLite handles, one file) under WAL, plus the path sandbox.
@Suite("Mapper ↔ lsqlite3 integration")
struct MapperSQLiteIntegrationTests {
    @Test("A plugin reads rooms/areas from the GRDB-written mapper DB")
    func pluginReadsMapperDatabase() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The mapper DB where a plugin expects it: <dir>/Aardwolf.db.
        let dbURL = dir.appendingPathComponent("Aardwolf.db")
        let store = try MapperStore(url: dbURL) // WAL, MUSHclient schema
        try store.upsert(Area(uid: "aylor", name: "Aylor"))
        try store.upsert(Room(uid: "32418", name: "Market Square", area: "aylor"))

        // A plugin-style read through the sandboxed sqlite3 global, with the
        // store still open (concurrent connections under WAL).
        let lua = try LuaRuntime()
        await lua.setSQLiteDirectory(dir.path)
        let effects = try await lua.run("""
        local db = sqlite3.open("\(dbURL.path)")
        local name, area = "", ""
        for row in db:nrows("SELECT r.name, a.name AS area FROM rooms r "
            .. "JOIN areas a ON a.uid = r.area WHERE r.uid = '32418'") do
          name, area = row.name, row.area
        end
        db:close()
        proteles.echo(name .. " / " .. area)
        """)
        #expect(effects == [.echo("Market Square / Aylor")])
    }
}

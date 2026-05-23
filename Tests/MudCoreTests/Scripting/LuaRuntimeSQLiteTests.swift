import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — lsqlite3 binding")
struct LuaRuntimeSQLiteTests {
    @Test("In-memory create/insert/read via the sqlite3 global")
    func inMemory() async throws {
        let lua = try LuaRuntime()
        let effects = try await lua.run("""
        local db = sqlite3.open(":memory:")
        db:exec("CREATE TABLE t(uid TEXT, name TEXT)")
        db:exec("INSERT INTO t VALUES('1','Square')")
        local got = ""
        for row in db:nrows("SELECT name FROM t WHERE uid='1'") do got = row.name end
        db:close()
        proteles.echo(got)
        """)
        #expect(effects == [.echo("Square")])
    }

    @Test("sqlite3.open is denied for a file outside the allowed directory")
    func pathDeniedByDefault() async throws {
        let lua = try LuaRuntime()
        // No directory configured → file opens are closed (in-memory still ok).
        let effects = try await lua.run("""
        local ok = pcall(function() return sqlite3.open("/tmp/proteles_should_deny.db") end)
        proteles.echo(ok and "opened" or "denied")
        """)
        #expect(effects == [.echo("denied")])
    }

    @Test("sqlite3.open is allowed for files under the configured directory")
    func pathAllowedInDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-allow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lua = try LuaRuntime()
        await lua.setSQLiteDirectory(dir.path)
        let file = dir.appendingPathComponent("plugin.db").path
        let effects = try await lua.run("""
        local db = sqlite3.open("\(file)")
        db:exec("CREATE TABLE t(x)")
        db:close()
        proteles.echo("ok")
        """)
        #expect(effects == [.echo("ok")])
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test("A path outside the allowed directory is still denied")
    func pathOutsideDirectoryDenied() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lua = try LuaRuntime()
        await lua.setSQLiteDirectory(dir.path)
        let effects = try await lua.run("""
        local ok = pcall(function() return sqlite3.open("/etc/passwd.db") end)
        proteles.echo(ok and "opened" or "denied")
        """)
        #expect(effects == [.echo("denied")])
    }
}

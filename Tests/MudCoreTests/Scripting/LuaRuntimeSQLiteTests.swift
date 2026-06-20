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

    @Test("close_vm + GC + close does not use-after-free (lsqlite3 GC hardening)")
    func closeVmThenGCThenCloseSurvives() async throws {
        // Regression for the v0.8.3 crash: db:close_vm() finalizes a statement's
        // vm and nils it but kept the registry entry; once that svm was GC'd the
        // original dbvm_gc skipped cleanup (vm == NULL), so the stale lightuserdata
        // key outlived the freed svm and a later cleanupdb (db:close()/db_gc)
        // dereferenced the dangling pointer — a SIGSEGV in luaH_get/mainposition.
        // The Search-and-Destroy plugin uses exactly this close_vm-without-close
        // pattern on many firings. Without the lsqlite3.c fix this test crashes
        // the whole test process rather than failing an expectation.
        let lua = try LuaRuntime()
        let effects = try await lua.run("""
        local db = sqlite3.open(":memory:")
        db:exec("CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3)")
        do
          local stmt = db:prepare("SELECT x FROM t")  -- svm registered, vm != NULL
          stmt:step()                                  -- stmt then goes out of scope
        end
        db:close_vm()              -- finalizes stmt's vm, nils it, leaves the entry
        collectgarbage("collect")  -- svm GC'd: entry would orphan, svm freed
        collectgarbage("collect")
        db:close()                 -- cleanupdb walks the (formerly dangling) entry
        proteles.echo("ok")
        """)
        #expect(effects == [.echo("ok")])
    }

    @Test("ATTACH is denied by the engine authorizer (sandbox can't be escaped)")
    func attachDenied() async throws {
        let lua = try LuaRuntime()
        // Even an in-memory open (always permitted) must refuse ATTACH, so a
        // plugin can't reach another file by attaching it through SQL — the
        // open-path guard alone wouldn't catch this.
        let effects = try await lua.run("""
        local db = sqlite3.open(":memory:")
        local code = db:exec("ATTACH DATABASE ':memory:' AS evil")
        db:close()
        proteles.echo(code == sqlite3.OK and "attached" or "denied")
        """)
        #expect(effects == [.echo("denied")])
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

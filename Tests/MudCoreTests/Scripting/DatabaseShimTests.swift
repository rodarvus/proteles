import Foundation
@testable import MudCore
import Testing

/// D3 — the MUSHclient `Database*` world API as a pure-Lua shim over the guarded
/// lsqlite3. Drives a full open → exec → prepare → step → column-read → close
/// round-trip through a real plugin, pinning the 1-indexed column semantics.
@Suite("Database* shim (D3)")
struct DatabaseShimTests {
    @Test("Database* round-trips and column accessors are 1-indexed")
    func databaseRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("t.db").path

        let engine = try ScriptEngine()
        await engine.setSQLiteDirectory(dir.path) // sandbox allows this dir
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.db" name="DB"/>
        <script><![CDATA[
        function OnPluginInstall()
          local DB = "tdb"
          proteles.send("open:" .. tostring(DatabaseOpen(DB, "\(dbPath)", 6) == sqlite3.OK))
          DatabaseExec(DB, "CREATE TABLE x(a, b)")
          DatabaseExec(DB, "INSERT INTO x VALUES('hi', 42)")
          DatabasePrepare(DB, "SELECT a, b FROM x")
          -- Column NAME must work right after prepare, BEFORE any step (lsqlite3's
          -- single-column get_name needs a stepped row; this is the live regression).
          proteles.send("prename2:" .. tostring(DatabaseColumnName(DB, 2)))
          proteles.send("step:" .. tostring(DatabaseStep(DB) == sqlite3.ROW))
          proteles.send("cols:" .. tostring(DatabaseColumns(DB)))
          proteles.send("info1:" .. tostring(DatabaseInfo(DB, 1):match("t%.db$") ~= nil))
          proteles.send("info2:" .. tostring(DatabaseInfo(DB, 2)))
          proteles.send("info3:" .. tostring(DatabaseInfo(DB, 3)))
          proteles.send("info4:" .. tostring(DatabaseInfo(DB, 4)))
          proteles.send("name1:" .. tostring(DatabaseColumnName(DB, 1)))
          proteles.send("val1:" .. tostring(DatabaseColumnValue(DB, 1)))
          proteles.send("val2:" .. tostring(DatabaseColumnValue(DB, 2)))
          proteles.send("type1:" .. tostring(DatabaseColumnType(DB, 1)))
          proteles.send("total:" .. tostring(DatabaseTotalChanges(DB)))
          local vals = DatabaseColumnValues(DB)
          proteles.send("vals:" .. tostring(vals[1]) .. "," .. tostring(vals[2]))
          proteles.send("done:" .. tostring(DatabaseStep(DB) == sqlite3.DONE))
          DatabaseFinalize(DB)
          DatabaseClose(DB)
          proteles.send("closed:" .. tostring(DatabaseColumns(DB)))
        end
        ]]></script></muclient>
        """)
        let effects = try await engine.loadPlugin(plugin)
        #expect(effects.contains(.send("open:true")))
        #expect(effects.contains(.send("prename2:b"))) // column name pre-step (1-indexed)
        #expect(effects.contains(.send("step:true")))
        #expect(effects.contains(.send("cols:2")))
        #expect(effects.contains(.send("info1:true")))
        #expect(effects.contains(.send("info2:true")))
        #expect(effects.contains(.send("info3:true")))
        #expect(effects.contains(.send("info4:2")))
        #expect(effects.contains(.send("name1:a"))) // 1-indexed -> column "a"
        #expect(effects.contains(.send("val1:hi")))
        #expect(effects.contains(.send("val2:42")))
        #expect(effects.contains(.send("type1:3"))) // sqlite3.TEXT
        #expect(effects.contains(.send("total:1")))
        #expect(effects.contains(.send("vals:hi,42"))) // get_values is 1-indexed
        #expect(effects.contains(.send("done:true")))
        #expect(effects.contains(.send("closed:0"))) // after close, the handle is gone
    }
}

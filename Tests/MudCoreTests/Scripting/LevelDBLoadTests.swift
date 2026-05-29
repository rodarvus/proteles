import Foundation
@testable import MudCore
import Testing

/// leveldb runs **verbatim** through the compat shim (like dinv). These load it
/// with a representative GMCP feed and assert it initialises + its command
/// surface responds with no Lua errors — the "verify by running" gate before a
/// live test. Any gap here is closed in the shim, never by editing the plugin.
@Suite("leveldb — load + smoke")
struct LevelDBLoadTests {
    private func loadLevelDB(in dir: URL) async throws -> (ScriptEngine, [ScriptEffect]) {
        let engine = try ScriptEngine()
        await engine.setSQLiteDirectory(dir.path)
        let suffixed = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        let context = PluginContext(
            pluginID: LevelDBAssets.pluginID,
            pluginName: "leveldb",
            pluginDirectory: suffixed,
            worldDirectory: suffixed,
            appDirectory: suffixed,
            stateDirectory: suffixed
        )
        let plugin = try MUSHclientPluginLoader.parse(xml: #require(LevelDBAssets.pluginXML))
        var effects = await engine.loadPlugin(plugin, context: context)
        effects += await engine.applyGMCP(
            package: "char.status",
            json: #"{"level":73,"state":3,"pos":"Standing"}"#
        )
        effects += await engine.applyGMCP(
            package: "char.base",
            json: #"{"name":"Tester","tier":0,"remort":0}"#
        )
        return (engine, effects)
    }

    private func luaErrors(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { effect in
            if case .note(let text, let fg, _) = effect, fg == "red" { return text }
            return nil
        }
    }

    @Test("leveldb loads + initialises through the compat shim with no Lua errors")
    func loadsClean() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leveldb-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (engine, effects) = try await loadLevelDB(in: dir)
        let errors = luaErrors(effects)
        #expect(errors.isEmpty, "leveldb load/init raised Lua errors: \(errors)")

        // open_db() ran at OnPluginInstall and created the SQLite file at the
        // path leveldb builds (`GetInfo(60) .. "state\\leveldb\\leveldb.db"`),
        // with the Windows backslashes normalised to "/" by the sqlite/mkdir
        // sandbox — i.e. <dir>/state/leveldb/leveldb.db.
        let dbPath = dir.appendingPathComponent("state/leveldb/leveldb.db").path
        #expect(
            FileManager.default.fileExists(atPath: dbPath),
            "leveldb.db wasn't created at the expected (backslash-normalised) path"
        )

        // The `ldb` command surface responds without erroring.
        let help = await engine.expandInput("ldb help")
        #expect(luaErrors(help).isEmpty, "`ldb help` raised Lua errors: \(luaErrors(help))")
    }
}

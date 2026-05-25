import Foundation
@testable import MudCore
import Testing

@Suite("dinv — load + smoke")
struct DinvLoadTests {
    /// Build a configured engine with dinv loaded into a temp state dir, plus a
    /// char.status (active) + char.base GMCP so dinv initializes (it gates init
    /// on the char.base broadcast when the state is active, and reads the
    /// character name for its per-character DB path).
    private func loadDinv(in dir: URL) async throws -> (ScriptEngine, [ScriptEffect]) {
        let engine = try ScriptEngine()
        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(dir.path)
        let suffixed = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        let context = PluginContext(
            pluginID: DinvAssets.pluginID,
            pluginName: "dinv",
            version: "3.0102",
            pluginDirectory: suffixed,
            worldDirectory: suffixed,
            appDirectory: suffixed,
            stateDirectory: suffixed
        )
        let plugin = try MUSHclientPluginLoader.parse(xml: #require(DinvAssets.pluginXML))
        var effects = await engine.loadPlugin(plugin, context: context)
        effects += await engine.applyGMCP(
            package: "char.status",
            json: #"{"level":150,"state":3,"pos":"Standing"}"#
        )
        effects += await engine.applyGMCP(package: "char.base", json: #"{"name":"Tester","class":"Mage"}"#)
        return (engine, effects)
    }

    private func luaErrors(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { effect in
            if case .note(let text, let fg, _) = effect, fg == "red" { return text }
            return nil
        }
    }

    @Test("dinv loads + initializes through the compat shim with no Lua errors")
    func loadsClean() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (engine, effects) = try await loadDinv(in: dir)
        let errors = luaErrors(effects)
        #expect(errors.isEmpty, "dinv load/init raised Lua errors: \(errors)")

        // The command surface responds (no crash); `dinv help` should output.
        let help = await engine.expandInput("dinv help")
        #expect(luaErrors(help).isEmpty, "dinv help raised: \(luaErrors(help))")
        #expect(!help.isEmpty, "dinv help produced no output")
    }

    @Test("gmcphelper gmcp() stringifies scalar leaves (char.status.state -> \"3\")")
    func gmcpStringifies() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        _ = await lua.applyGMCP(package: "char.status", json: #"{"state":3,"level":9}"#)
        #expect(try await lua.string(
            #"(function() require "gmcphelper"; return tostring(gmcp("char.status").state) end)()"#
        ) == "3")
        #expect(try await lua.string(
            #"(function() require "gmcphelper"; return tostring(gmcp("char.status").level) end)()"#
        ) == "9")
    }

    @Test("sqlite3.open normalizes Windows-style backslash paths")
    func sqliteBackslashNormalized() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-bs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        await lua.setSQLiteDirectory(base.path)
        let ok = try await lua.string("""
        (function()
          local db = sqlite3.open("\(base.path)\\\\sub\\\\t.db")
          if not db then return "nil" end
          db:exec("CREATE TABLE x(a)"); db:close(); return "ok"
        end)()
        """)
        #expect(ok == "ok")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("sub/t.db").path))
    }
}

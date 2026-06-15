import Foundation
@testable import MudCore
import Testing

/// `require` of a plugin's own split-out `.lua` files runs them in that plugin's
/// environment (like `dofile`), so their globals are private to the plugin and
/// visible to the rest of its code — not leaked into the shared `_G` where they
/// collide across plugins. Repro for a player whose multi-file plugin (a file
/// defining `xc = {}; function xc.foo()`) misbehaved. Bundled helpers keep their
/// shared-`_G` behaviour (verified below) so `gmcp`/`serialize`/… stay global.
@Suite("Plugin require() — plugin-local module isolation")
struct PluginRequireModuleTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-require-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ source: String, _ name: String, in dir: URL) throws {
        try source.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("a require'd module's global table is visible to the plugin's trigger scripts")
    func moduleTableVisibleInPlugin() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            """
            xc = { in_combat = false, count = 0 }
            function xc.combat_start()
              xc.in_combat = true
              xc.count = xc.count + 1
            end
            """,
            "shared_core.lua",
            in: dir
        )

        let lua = try LuaRuntime()
        await lua.setModuleSearchPaths([dir.path])
        await lua.createPluginEnvironment("p")
        _ = await lua.loadPluginScript(#"require("shared_core")"#, pluginID: "p")
        let effects = await lua.runPluginScript(
            #"xc.combat_start(); proteles.send(tostring(xc.in_combat) .. "/" .. tostring(xc.count))"#,
            pluginID: "p"
        )
        #expect(effects == [.send("true/1")])
    }

    @Test("a require'd module's globals do NOT leak to another plugin")
    func moduleTableIsolatedAcrossPlugins() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("xc = { tag = \"A\" }", "shared_core.lua", in: dir)

        let lua = try LuaRuntime()
        await lua.setModuleSearchPaths([dir.path])
        await lua.createPluginEnvironment("a")
        await lua.createPluginEnvironment("b")
        _ = await lua.loadPluginScript(#"require("shared_core")"#, pluginID: "a")
        // Plugin B never required it; it must not see plugin A's `xc`.
        let effects = await lua.runPluginScript(#"proteles.send(tostring(xc))"#, pluginID: "b")
        #expect(effects == [.send("nil")])
    }

    @Test("a require'd module can see globals the plugin defined in its own env")
    func moduleSeesPluginGlobals() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"READBACK = pluginGlobal"#, "reader.lua", in: dir)

        let lua = try LuaRuntime()
        await lua.setModuleSearchPaths([dir.path])
        await lua.createPluginEnvironment("p")
        _ = await lua.loadPluginScript(#"pluginGlobal = "hi"; require("reader")"#, pluginID: "p")
        let effects = await lua.runPluginScript(#"proteles.send(tostring(READBACK))"#, pluginID: "p")
        #expect(effects == [.send("hi")])
    }

    @Test("two of a plugin's own files share globals through the plugin env")
    func pluginFilesShareGlobals() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"shared = { value = 7 }"#, "lib_a.lua", in: dir)
        try write(#"result = shared.value * 2"#, "lib_b.lua", in: dir)

        let lua = try LuaRuntime()
        await lua.setModuleSearchPaths([dir.path])
        await lua.createPluginEnvironment("p")
        _ = await lua.loadPluginScript(#"require("lib_a"); require("lib_b")"#, pluginID: "p")
        let effects = await lua.runPluginScript(#"proteles.send(tostring(result))"#, pluginID: "p")
        #expect(effects == [.send("14")])
    }

    @Test("bundled helpers still load into the shared global env (unchanged)")
    func bundledHelpersStayGlobal() async throws {
        let lua = try LuaRuntime()
        // A bundled helper that defines a global (like gmcphelper's `gmcp`).
        await lua.registerModule("widgets", source: "WIDGETS = { ok = true }\nreturn WIDGETS")
        await lua.createPluginEnvironment("a")
        await lua.createPluginEnvironment("b")
        _ = await lua.loadPluginScript(#"require("widgets")"#, pluginID: "a")
        // Plugin B, which never required it, still sees the global — bundled
        // helpers are intentionally shared, matching pre-fix behaviour.
        let effects = await lua.runPluginScript(#"proteles.send(type(WIDGETS))"#, pluginID: "b")
        #expect(effects == [.send("table")])
    }
}

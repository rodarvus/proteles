import Foundation
@testable import MudCore
import Testing

/// `require` reaching a plugin's split-out files in a `lua/` subfolder and via
/// the plugin's own `package.path` — the multi-file plugin require fix. Before this,
/// `require` searched only the plugin directory root (not `lua/`) and ignored
/// `package.path` entirely, and `package.config`/`package.path` were nil (his
/// separator defaulted to "\\" on macOS and `… .. package.path` crashed).
@Suite("Plugin require() — lua/ subfolder + package.path")
struct PluginRequirePackagePathTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-pkgpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ source: String, _ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try source.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("require finds a module in the plugin's lua/ subfolder (no package.path)")
    func requireLuaSubfolder() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("xc = { ready = true }", "shared_core.lua", in: dir.appendingPathComponent("lua"))

        let lua = try LuaRuntime()
        await lua.setModuleSearchPaths([dir.path])
        await lua.createPluginEnvironment("p")
        _ = await lua.loadPluginScript(#"require("shared_core")"#, pluginID: "p")
        let effects = await lua.runPluginScript(#"proteles.send(tostring(xc.ready))"#, pluginID: "p")
        #expect(effects == [.send("true")])
    }

    @Test("require honors the plugin's package.path entries")
    func requireHonorsPackagePath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vendor = dir.appendingPathComponent("vendor")
        try write("utility = { version = 3 }", "utility.lua", in: vendor)

        let lua = try LuaRuntime()
        try await lua.loadCompatShim() // provides package.path / package.config
        await lua.setModuleSearchPaths([dir.path]) // sandbox root (vendor is under it)
        await lua.createPluginEnvironment("p")
        // Prepend the vendor subdir to package.path, the way a multi-file plugin does.
        _ = await lua.loadPluginScript(
            #"package.path = "\#(vendor.path)/?.lua;" .. package.path; require("utility")"#,
            pluginID: "p"
        )
        let effects = await lua.runPluginScript(#"proteles.send(tostring(utility.version))"#, pluginID: "p")
        #expect(effects == [.send("3")])
    }

    @Test("package.config and package.path are present (Unix sep; no nil-concat crash)")
    func packageFieldsRestored() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        proteles.echo(package.config:sub(1, 1))
        proteles.echo(type(package.path))
        proteles.echo("ok:" .. package.path)
        """)
        #expect(effects == [.echo("/"), .echo("string"), .echo("ok:?.lua")])
    }
}

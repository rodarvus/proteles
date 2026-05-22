import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — controlled require / dofile")
struct LuaRuntimeModulesTests {
    @Test("require loads a bundled module and returns its value")
    func requireBundled() async throws {
        let lua = try LuaRuntime()
        await lua.registerModule(
            "greet",
            source: #"return { hello = function() proteles.echo("hi") end }"#
        )
        let effects = try await lua.run("local g = require('greet'); g.hello()")
        #expect(effects == [.echo("hi")])
    }

    @Test("require caches: the module loads only once")
    func requireCaches() async throws {
        let lua = try LuaRuntime()
        // The module body bumps a global each time it's executed, then
        // returns the count. A cached require must not re-run the body.
        await lua.registerModule("counter", source: "loads = (loads or 0) + 1; return loads")
        let effects = try await lua.run(
            "proteles.echo(tostring(require('counter')) .. tostring(require('counter')))"
        )
        #expect(effects == [.echo("11")])
    }

    @Test("require of an unknown module raises a Lua error")
    func requireMissing() async throws {
        let lua = try LuaRuntime()
        await #expect(throws: (any Error).self) {
            try await lua.run("require('does_not_exist')")
        }
    }

    @Test("dofile reads a file inside an allowed search path")
    func dofileAllowed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-dofile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("script.lua")
        try #"proteles.echo("from file")"#.write(to: file, atomically: true, encoding: .utf8)

        let lua = try LuaRuntime()
        await lua.setModuleSearchPaths([directory.path])
        let effects = try await lua.run("dofile([[\(file.path)]])")
        #expect(effects == [.echo("from file")])
    }

    @Test("dofile outside the allowed paths is refused")
    func dofileRefused() async throws {
        let lua = try LuaRuntime()
        await lua.setModuleSearchPaths(["/tmp/proteles-allowed-nonexistent"])
        await #expect(throws: (any Error).self) {
            try await lua.run("dofile('/etc/hosts')")
        }
    }
}

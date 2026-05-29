import Foundation
@testable import MudCore
import Testing

/// Compat-shim additions surfaced by auditing real community plugins (loaded +
/// run through the shim): `check`, `SaveState`, the GMCP-handler `gmcpval`
/// CallPlugin bridge, `dofile` Windows-path normalisation, and a sandboxed `io`.
@Suite("LuaRuntime — community-plugin shim additions")
struct ShimCompatAdditionsTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("require returns an already-loaded stdlib library (string/math)")
    func requireStdlib() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(tostring(require("string") == string))
        proteles.echo(tostring(require("math") == math))
        """)
        #expect(effects == [.echo("true"), .echo("true")])
    }

    @Test("Accelerator / AcceleratorTo are defined and return eOK")
    func acceleratorStubs() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(tostring(AcceleratorTo("Ctrl+P", "x", 12) == error_code.eOK))
        proteles.echo(type(Accelerator))
        """)
        #expect(effects == [.echo("true"), .echo("function")])
    }

    @Test("check() passes eOK through and errors on a non-eOK code")
    func checkGuard() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(tostring(check(error_code.eOK)))
        proteles.echo(tostring((pcall(function() check(30001) end))))
        """)
        #expect(effects == [.echo("0"), .echo("false")])
    }

    @Test("SaveState() runs OnPluginSaveState so its SetVariables persist")
    func saveStateRunsCallback() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        function OnPluginSaveState() SetVariable("saved", "yes") end
        SaveState()
        proteles.echo(GetVariable("saved") or "nil")
        """)
        #expect(effects == [.echo("yes")])
    }

    @Test("CallPlugin(gmcp handler, gmcpval, path) returns a loadstring-able literal")
    func gmcpvalCallPluginBridge() async throws {
        let lua = try await shimmed()
        await lua.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        let effects = try await lua.run("""
        local _, s = CallPlugin("3e7dedbe37e44942dd46d264", "gmcpval", "char.status")
        assert(loadstring("gmcpdata = " .. s))()
        proteles.echo(tostring(gmcpdata.state))
        """)
        #expect(effects == [.echo("3")])
    }

    @Test("dofile with Windows backslashes resolves a bundled helper by basename")
    func dofileBackslashResolves() async throws {
        let lua = try await shimmed()
        // Build a backslash path (as MUSHclient plugins do) without escape
        // ambiguity, pointing at the bundled aardwolf_colors helper.
        let effects = try await lua.run("""
        local bs = string.char(92)
        local path = "x" .. bs .. "y" .. bs .. "aardwolf_colors.lua"
        proteles.echo(tostring(pcall(dofile, path)))
        """)
        #expect(effects == [.echo("true")])
    }

    @Test("sandboxed io.lines reads a file inside the sandbox; outside is denied")
    func sandboxedIO() async throws {
        let lua = try await shimmed()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha\nbeta".write(to: dir.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
        await lua.setSQLiteDirectory(dir.path)

        let inside = try await lua.run("""
        for line in io.lines("\(dir.path)/list.txt") do proteles.echo(line) end
        """)
        #expect(inside == [.echo("alpha"), .echo("beta")])

        // A path outside the sandbox root can't be opened.
        let outside = try await lua.run("""
        proteles.echo(tostring(io.open("/etc/hosts", "r") == nil))
        """)
        #expect(outside == [.echo("true")])
    }
}

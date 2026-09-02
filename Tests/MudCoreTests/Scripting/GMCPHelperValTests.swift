import Foundation
@testable import MudCore
import Testing

/// `gmcphelper`'s two distinct accessors. `gmcp(path)` is absolute over the live
/// `proteles.gmcp` table; `gmcpval(field)` is **relative to the caller's
/// `gmcpdata`** — the canonical package idiom (`aard_GMCP_mapper.xml:3954`,
/// Galaban's Partroxis plugin). Proteles aliased `gmcp = gmcpval`, so
/// `gmcpval("num")` looked for a top-level GMCP package called `num`, returned
/// `""`, and every plugin using the idiom got a nil room id.
@Suite("gmcphelper — gmcpval over gmcpdata")
struct GMCPHelperValTests {
    private let roomInfo = #"""
    {"num":5764,"name":"In the Mountains","zone":"partroxis",
     "terrain":"mountain","details":"maze",
     "exits":{"n":-1},"coord":{"id":0,"x":11,"y":27,"cont":0}}
    """#

    private func shimmedPlugin() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        await lua.createPluginEnvironment("p")
        return lua
    }

    @Test("the Partroxis idiom: CallPlugin → gmcpdata → gmcpval(\"num\") is the room id")
    func gmcpvalResolvesAgainstGmcpdata() async throws {
        let lua = try await shimmedPlugin()
        await lua.applyGMCP(package: "room.info", json: roomInfo)
        let effects = await lua.runPluginScript("""
        require "gmcphelper"
        local _, arg = CallPlugin("3e7dedbe37e44942dd46d264", "gmcpval", "room.info")
        assert(loadstring("gmcpdata = " .. arg))()
        proteles.send(tostring(tonumber(gmcpval("num"))))
        """, pluginID: "p")
        #expect(effects == [.send("5764")])
    }

    @Test("a nested field resolves relative to gmcpdata (the mapper's gmcpval(\"coord.x\"))")
    func gmcpvalResolvesNestedField() async throws {
        let lua = try await shimmedPlugin()
        await lua.applyGMCP(package: "room.info", json: roomInfo)
        let effects = await lua.runPluginScript("""
        require "gmcphelper"
        local _, arg = CallPlugin("3e7dedbe37e44942dd46d264", "gmcpval", "room.info")
        assert(loadstring("gmcpdata = " .. arg))()
        proteles.send(gmcpval("coord.x") .. "," .. gmcpval("zone"))
        """, pluginID: "p")
        #expect(effects == [.send("11,partroxis")])
    }

    @Test("a field missing from gmcpdata returns \"\", as upstream get_gmcp does")
    func missingFieldIsEmptyString() async throws {
        let lua = try await shimmedPlugin()
        await lua.applyGMCP(package: "room.info", json: roomInfo)
        let effects = await lua.runPluginScript("""
        require "gmcphelper"
        gmcpdata = { num = "5764" }
        proteles.send("[" .. gmcpval("nosuchfield") .. "]")
        """, pluginID: "p")
        #expect(effects == [.send("[]")])
    }

    @Test("with no gmcpdata set, gmcpval falls back to the absolute live walk")
    func fallsBackToAbsoluteWalkWithoutGmcpdata() async throws {
        let lua = try await shimmedPlugin()
        await lua.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        let effects = await lua.runPluginScript("""
        require "gmcphelper"
        proteles.send(tostring(gmcpval("char.status.state")))
        """, pluginID: "p")
        #expect(effects == [.send("3")])
    }

    @Test("gmcp(path) stays absolute and is no longer an alias for gmcpval")
    func gmcpStaysAbsolute() async throws {
        let lua = try await shimmedPlugin()
        await lua.applyGMCP(package: "room.info", json: roomInfo)
        let effects = await lua.runPluginScript("""
        require "gmcphelper"
        gmcpdata = { num = "1" } -- must NOT influence gmcp()
        proteles.send(gmcp("room.info.num") .. "," .. tostring(gmcp ~= gmcpval))
        """, pluginID: "p")
        #expect(effects == [.send("5764,true")])
    }
}

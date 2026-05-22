import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — GMCP projection")
struct LuaRuntimeGMCPTests {
    @Test("A message populates a nested proteles.gmcp table with native types")
    func populatesNestedTable() async throws {
        let lua = try LuaRuntime()
        await lua.applyGMCP(
            package: "char.vitals",
            json: #"{"hp":2226,"mana":900,"str":"ok"}"#
        )
        // Numbers stay numbers; strings stay strings.
        #expect(try await lua.number("proteles.gmcp.char.vitals.hp") == 2226)
        #expect(try await lua.number("proteles.gmcp.char.vitals.mana") == 900)
        #expect(try await lua.string("proteles.gmcp.char.vitals.str") == "ok")
    }

    @Test("Arrays decode to 1-based Lua tables")
    func arraysAreOneBased() async throws {
        let lua = try LuaRuntime()
        await lua.applyGMCP(package: "comm.test", json: #"{"items":[10,20,30]}"#)
        #expect(try await lua.number("#proteles.gmcp.comm.test.items") == 3)
        #expect(try await lua.number("proteles.gmcp.comm.test.items[1]") == 10)
        #expect(try await lua.number("proteles.gmcp.comm.test.items[3]") == 30)
    }

    @Test("Booleans decode to Lua booleans")
    func booleansDecode() async throws {
        let lua = try LuaRuntime()
        await lua.applyGMCP(package: "char.flags", json: #"{"wimpy":true,"afk":false}"#)
        #expect(try await lua.boolean("proteles.gmcp.char.flags.wimpy"))
        #expect(try await lua.boolean("proteles.gmcp.char.flags.afk == false"))
    }

    @Test("A later message replaces the leaf table wholesale")
    func leafIsReplaced() async throws {
        let lua = try LuaRuntime()
        await lua.applyGMCP(package: "char.vitals", json: #"{"hp":100,"mana":50}"#)
        await lua.applyGMCP(package: "char.vitals", json: #"{"hp":120}"#)
        #expect(try await lua.number("proteles.gmcp.char.vitals.hp") == 120)
        // The old `mana` key is gone (replace, not merge).
        #expect(try await lua.boolean("proteles.gmcp.char.vitals.mana == nil"))
    }

    @Test("A single-component package nests one level deep")
    func singleComponentPackage() async throws {
        let lua = try LuaRuntime()
        await lua.applyGMCP(package: "group", json: #"{"size":3}"#)
        #expect(try await lua.number("proteles.gmcp.group.size") == 3)
    }

    @Test("An event fires for each path level, carrying the full package name")
    func raisesPerLevelEvents() async throws {
        let lua = try LuaRuntime()
        // Register handlers for both levels; each records what it saw.
        try await lua.run("""
        seen = {}
        proteles.onEvent('gmcp.char', function(key) seen.parent = key end)
        proteles.onEvent('gmcp.char.vitals', function(key)
            seen.leaf = key
            proteles.send('hp is ' .. proteles.gmcp.char.vitals.hp)
        end)
        """)
        let effects = await lua.applyGMCP(package: "char.vitals", json: #"{"hp":777}"#)
        #expect(effects == [.send("hp is 777")])
        #expect(try await lua.string("seen.parent") == "char.vitals")
        #expect(try await lua.string("seen.leaf") == "char.vitals")
    }

    @Test("A malformed payload stores an empty table without throwing")
    func malformedPayloadIsSafe() async throws {
        let lua = try LuaRuntime()
        await lua.applyGMCP(package: "char.vitals", json: "not json")
        // The leaf exists as a table, just empty.
        #expect(try await lua.boolean("type(proteles.gmcp.char.vitals) == 'table'"))
        #expect(try await lua.boolean("next(proteles.gmcp.char.vitals) == nil"))
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — bundled helper libraries")
struct CompatHelpersTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("gmcphelper reads the live proteles.gmcp table, stringifying leaves")
    func gmcpHelperReadsNativeGMCP() async throws {
        let lua = try await shimmed()
        await lua.applyGMCP(package: "char.status", json: #"{"state":3,"enemy":"a rat"}"#)
        try await lua.run("require('gmcphelper')")
        // Leaf scalars come back as strings (Aardwolf plugins compare them so).
        #expect(try await lua.string("gmcp('char.status.state')") == "3")
        #expect(try await lua.string("gmcp('char.status.enemy')") == "a rat")
        // A table node is returned as a table; a missing path returns "" (the
        // reference gmcphelper's `… or ""`), so indexing it is harmlessly nil
        // (string index) rather than a nil-index crash.
        #expect(try await lua.boolean("type(gmcp('char.status')) == 'table'"))
        #expect(try await lua.boolean("gmcp('char.nope.missing') == ''"))
        #expect(try await lua.boolean("gmcp('char.nope.missing').state == nil"))
    }

    @Test("copytable.deep makes an independent copy")
    func copytableDeep() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        local copytable = require('copytable')
        local original = { a = 1, nested = { b = 2 } }
        local clone = copytable.deep(original)
        clone.nested.b = 99
        proteles.echo(tostring(original.nested.b) .. '/' .. tostring(clone.nested.b))
        """)
        #expect(effects == [.echo("2/99")])
    }

    @Test("commas groups a number's integer part")
    func commasGroups() async throws {
        let lua = try await shimmed()
        #expect(try await lua.string("require('commas')(1234567)") == "1,234,567")
        #expect(try await lua.string("require('commas')(-1000)") == "-1,000")
    }

    @Test("pairsByKeys iterates in sorted key order")
    func pairsByKeysSorted() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        local pairsByKeys = require('pairsbykeys')
        local out = {}
        for k in pairsByKeys({ c = 1, a = 1, b = 1 }) do out[#out + 1] = k end
        proteles.echo(table.concat(out, ','))
        """)
        #expect(effects == [.echo("a,b,c")])
    }

    @Test("tprint writes table contents via Note")
    func tprintEchoes() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("require('tprint')({ x = 1 })")
        #expect(effects == [.echo("x = 1")])
    }
}

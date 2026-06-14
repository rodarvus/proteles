import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — scoped variables")
struct LuaRuntimeVariableTests {
    @Test("setVar then getVar round-trips within a scope")
    func setGetRoundTrip() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.setVar('hp', '100')")
        #expect(await lua.variables(inScope: "_user")["hp"] == "100")
        let effects = try await lua.run("proteles.send(proteles.getVar('hp'))")
        #expect(effects == [.send("100")])
    }

    @Test("getVar returns nil for an unset variable (MUSHclient parity)")
    func missingIsNil() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.boolean("proteles.getVar('nope') == nil"))
    }

    @Test("Variables are isolated per scope")
    func scopeIsolation() async throws {
        let lua = try LuaRuntime()
        await lua.setVariableScope("pluginA")
        try await lua.run("proteles.setVar('x', '1')")
        await lua.setVariableScope("pluginB")
        #expect(try await lua.boolean("proteles.getVar('x') == nil"))
        await lua.setVariableScope("pluginA")
        #expect(try await lua.boolean("proteles.getVar('x') == '1'"))
    }

    @Test("deleteVar removes a variable")
    func deleteRemoves() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.setVar('y', '2'); proteles.deleteVar('y')")
        #expect(try await lua.boolean("proteles.getVar('y') == nil"))
    }

    @Test("Dirty scopes track writes and clear when taken")
    func dirtyTracking() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.setVar('a', '1')")
        #expect(await lua.takeDirtyVariableScopes() == ["_user"])
        // Cleared after being taken.
        #expect(await lua.takeDirtyVariableScopes().isEmpty)
    }

    @Test("varList returns the current scope's variables as a name→value table")
    func varListCurrentScope() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.setVar('a', '1'); proteles.setVar('b', '2')")
        let effects = try await lua.run("""
        local t = proteles.varList()
        proteles.send(tostring(t.a) .. ',' .. tostring(t.b))
        """)
        #expect(effects == [.send("1,2")])
    }

    @Test("varList(scope) reads a named scope; an unknown scope is an empty table")
    func varListByScope() async throws {
        let lua = try LuaRuntime()
        await lua.setVariableScope("pluginA")
        try await lua.run("proteles.setVar('x', '9')")
        await lua.setVariableScope("_user")
        #expect(try await lua.boolean("proteles.varList('pluginA').x == '9'"))
        // Unknown scope → empty table, never nil (MUSHclient parity).
        #expect(try await lua.boolean("type(proteles.varList('nope')) == 'table'"))
        #expect(try await lua.boolean("next(proteles.varList('nope')) == nil"))
    }

    @Test("A snapshot reloads into another runtime")
    func snapshotRoundTrip() async throws {
        let lua = try LuaRuntime()
        await lua.setVariableScope("p")
        try await lua.run("proteles.setVar('k', 'v')")
        let snapshot = await lua.variablesSnapshot()

        let other = try LuaRuntime()
        await other.loadVariables(snapshot)
        await other.setVariableScope("p")
        #expect(try await other.boolean("proteles.getVar('k') == 'v'"))
        // loadVariables clears the dirty set.
        #expect(await other.takeDirtyVariableScopes().isEmpty)
    }
}

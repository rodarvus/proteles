import Foundation
@testable import MudCore
import Testing

/// The MUSHclient variable surface a migrant relies on, exercised through the
/// compat shim: `GetVariableList`/`GetPluginVariableList` (previously missing or
/// empty stubs) and the bundled `var` helper (the `var.foo = x` auto-persist
/// idiom). See `submodules/mushclient/lua/var.lua` and methods_variables.cpp.
@Suite("Variables — GetVariableList + var helper (compat shim)")
struct VariableListAndVarHelperTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("GetVariableList returns every current-scope variable as name→value")
    func getVariableList() async throws {
        let lua = try await shimmed()
        try await lua.run("SetVariable('target', 'kobold'); SetVariable('hp', '50')")
        #expect(try await lua.string("GetVariableList().target") == "kobold")
        #expect(try await lua.string("GetVariableList().hp") == "50")
    }

    @Test("GetVariableList is an empty table (not nil) for an empty scope")
    func getVariableListEmpty() async throws {
        let lua = try await shimmed()
        #expect(try await lua.boolean("type(GetVariableList()) == 'table'"))
        #expect(try await lua.boolean("next(GetVariableList()) == nil"))
    }

    @Test("GetPluginVariableList reads a named plugin's scope")
    func getPluginVariableList() async throws {
        let lua = try await shimmed()
        await lua.setVariableScope("plugin123")
        try await lua.run("SetVariable('k', 'v')")
        await lua.setVariableScope("_user")
        #expect(try await lua.string("GetPluginVariableList('plugin123').k") == "v")
    }

    @Test("var.foo persists via SetVariable, reads back, and nil deletes")
    func varHelperRoundTrip() async throws {
        let lua = try await shimmed()
        try await lua.run("require('var').target = 'kobold'")
        // Persisted through to the real variable store…
        #expect(try await lua.string("GetVariable('target')") == "kobold")
        // …and readable back through the table interface.
        #expect(try await lua.string("require('var').target") == "kobold")
        // Assigning nil deletes it (matching the reference var.lua).
        try await lua.run("require('var').target = nil")
        #expect(try await lua.boolean("GetVariable('target') == nil"))
    }

    @Test("var coerces non-string values to strings on write")
    func varHelperCoerces() async throws {
        let lua = try await shimmed()
        try await lua.run("require('var').count = 42")
        #expect(try await lua.string("GetVariable('count')") == "42")
    }
}

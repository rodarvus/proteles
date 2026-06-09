import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — require 'string_split' (Nick Gammon lua/ helper)")
struct StringSplitModuleTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("require 'string_split' resolves and defines string.split")
    func resolves() async throws {
        let lua = try await shimmed()
        // The Hadar plugins do exactly this at load (was failing: module not found).
        let effects = try await lua.run("""
        require 'string_split'
        local parts = string.split('a,b,c', ',')
        Note(#parts .. ':' .. parts[1] .. parts[2] .. parts[3])
        """)
        #expect(effects.contains { effect in
            if case .echo(let text) = effect { return text == "3:abc" }
            return false
        })
    }

    @Test("MUSHHelperAssets exposes string_split for registration")
    func bundled() {
        #expect(MUSHHelperAssets.lua("string_split")?.contains("function string.split") == true)
        #expect(MUSHHelperAssets.modules["string_split"] != nil)
    }
}

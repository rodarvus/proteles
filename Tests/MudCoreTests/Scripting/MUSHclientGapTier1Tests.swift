import Foundation
@testable import MudCore
import Testing

/// Tier-1 world functions added to the generic plugin shim from the
/// MUSHclient↔Proteles gap audit (`docs/MUSHCLIENT_LUA_GAP.md`): the
/// highest-usage missing globals that are pure or already have a primitive.
/// Each test fails without the addition (the global would be a nil-call error).
@Suite("Generic shim — MUSHclient gap Tier 1")
struct MUSHclientGapTier1Tests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("ANSI builds the exact escape sequence; no args -> reset")
    func ansi() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(ANSI(1, 31))
        proteles.echo(ANSI(0))
        proteles.echo(ANSI())
        """)
        #expect(effects == [.echo("\u{1B}[1;31m"), .echo("\u{1B}[0m"), .echo("\u{1B}[m")])
    }

    @Test("Simulate injects text through the inbound pipeline and returns eOK")
    func simulate() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        local rc = Simulate("You are hungry.")
        proteles.echo(tostring(rc == error_code.eOK))
        """)
        #expect(effects == [.simulate("You are hungry."), .echo("true")])
    }

    @Test("WorldName returns a string (GetInfo(2), or the default)")
    func worldName() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("proteles.echo(type(WorldName()))")
        #expect(effects == [.echo("string")])
    }
}

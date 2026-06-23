@testable import MudCore
import Testing

@Suite("LuaRuntime - TextRectangle shim")
struct TextRectangleShimTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("TextRectangle state round-trips through MUSHclient GetInfo geometry codes")
    func textRectangleGetInfoRoundTrip() async throws {
        let lua = try await shimmed()
        await lua.setOutputGeometry(width: 1024, height: 768)
        let effects = try await lua.run("""
        local ok = TextRectangle(10, 20, -30, -40, 5, 111, 2, 222, 7) == error_code.eOK
        proteles.echo("set:" .. tostring(ok))
        proteles.echo("declared:" .. table.concat({
          GetInfo(272), GetInfo(273), GetInfo(274), GetInfo(275),
          GetInfo(276), GetInfo(282), GetInfo(277), GetInfo(278), GetInfo(279)
        }, ","))
        proteles.echo("actual:" .. table.concat({
          GetInfo(290), GetInfo(291), GetInfo(292), GetInfo(293)
        }, ","))
        TextRectangle(0, 0, 0, 0, 0, 0, 0, 0, 0)
        proteles.echo("reset-actual:" .. table.concat({
          GetInfo(290), GetInfo(291), GetInfo(292), GetInfo(293)
        }, ","))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == [
            "set:true",
            "declared:10,20,-30,-40,5,111,2,222,7",
            "actual:5,15,999,733",
            "reset-actual:0,0,1024,768"
        ])
    }
}

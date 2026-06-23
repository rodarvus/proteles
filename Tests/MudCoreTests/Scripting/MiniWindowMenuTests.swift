@testable import MudCore
import Testing

@Suite("MiniWindow — WindowMenu")
struct MiniWindowMenuTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("WindowMenu parses MUSHclient menu syntax and returns selected text")
    func windowMenuReturnsSelectedText() async throws {
        let lua = try await shimmed()
        final class Box: @unchecked Sendable {
            var request: MiniWindowMenuRequest?
        }
        let box = Box()
        await lua.setMiniWindowMenuProvider { request in
            box.request = request
            return MiniWindowMenuSelection(title: "Beta", index: 2)
        }

        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 100, 50, 0, 0, 0)
        proteles.echo(WindowMenu("w", 10, 20, "~cbAlpha|+Beta|^Disabled|>|Sub|<"))
        """)
        #expect(effects.contains(.echo("Beta")))
        #expect(box.request?.horizontalAlignment == .center)
        #expect(box.request?.verticalAlignment == .bottom)
        #expect(box.request?.items[1].checked == true)
        #expect(box.request?.items[2].disabled == true)
        #expect(box.request?.items[3].children.first?.title == "Sub")
    }

    @Test("WindowMenu numeric mode returns the selected ordinal")
    func windowMenuNumericMode() async throws {
        let lua = try await shimmed()
        await lua.setMiniWindowMenuProvider { _ in MiniWindowMenuSelection(title: "Two", index: 2) }

        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 100, 50, 0, 0, 0)
        proteles.echo(WindowMenu("w", 1, 1, "!One|Two|Three"))
        proteles.echo(WindowMenu("w", 101, 1, "Bad"))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["2", ""])
    }
}

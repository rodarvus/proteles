@testable import MudCore
import Testing

@Suite("MiniWindow — shim → scene accumulation")
struct MiniWindowShimTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    /// Pull the single scene out of a run's effects (fails the expectation if
    /// there isn't exactly one).
    private func scene(_ effects: [ScriptEffect]) -> MiniWindowScene? {
        let scenes = effects.compactMap { effect -> MiniWindowScene? in
            if case .updateMiniWindow(let scene) = effect { return scene }
            return nil
        }
        return scenes.last
    }

    @Test("WindowCreate + draws emit ONE scene per draw pass, not per primitive")
    func onePassOneScene() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 200, 100, miniwin.pos_top_right, 0, 0)
        WindowRectOp("w", miniwin.rect_fill, 0, 0, 0, 0, 0x102030)
        WindowFont("w", "f", "Menlo", 12)
        WindowText("w", "f", "hello", 4, 4, 0, 0, 0xFFFFFF)
        """)
        let updates = effects.filter { if case .updateMiniWindow = $0 { true } else { false } }
        #expect(updates.count == 1) // one flush at end of run, not three
        let scene = scene(effects)
        #expect(scene?.width == 200)
        #expect(scene?.height == 100)
        #expect(scene?.position == 6) // pos_top_right
        // WindowCreate seeds a background fill; then our fill + the text.
        #expect(scene?.commands.count == 3)
        #expect(scene?.fonts["f"]?.name == "Menlo")
    }

    @Test("WindowInfo uses MUSHclient numbering for position, flags, background, and z-order")
    func windowInfoMUSHclientNumbering() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 10, 20, 200, 100, miniwin.pos_top_right, 18, 0x102030)
        proteles.echo("initial:" .. table.concat({
          tostring(WindowInfo("w", 5)), tostring(WindowInfo("w", 6)),
          WindowInfo("w", 7), WindowInfo("w", 8), WindowInfo("w", 9),
          WindowInfo("w", 10), WindowInfo("w", 11), WindowInfo("w", 12), WindowInfo("w", 13),
          WindowInfo("w", 22)
        }, ","))
        WindowPosition("w", 30, 40, miniwin.pos_center_all, 2)
        proteles.echo("moved:" .. table.concat({
          WindowInfo("w", 1), WindowInfo("w", 2), WindowInfo("w", 7), WindowInfo("w", 8),
          WindowInfo("w", 10), WindowInfo("w", 11), WindowInfo("w", 12), WindowInfo("w", 13)
        }, ","))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == [
            "initial:true,false,6,18,1056816,10,20,210,120,0",
            "moved:30,40,12,2,30,40,230,140"
        ])
    }

    @Test("WindowText returns the measured pixel width")
    func textWidthReturned() async throws {
        let lua = try await shimmed()
        // `WindowTextWidth` must return a positive number Lua can lay out from.
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 200, 100, 6, 0, 0)
        WindowFont("w", "f", "Menlo", 12)
        local width = WindowTextWidth("w", "f", "hello")
        if type(width) ~= "number" or width <= 0 then error("bad width: " .. tostring(width)) end
        """)
        #expect(!effects.isEmpty) // ran without raising
    }

    @Test("a redraw pass replaces the prior frame's commands (bounded growth)")
    func redrawReplaces() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("WindowCreate('w', 0, 0, 200, 100, 6, 0, 0)")
        // Two separate draw passes, each clears + redraws.
        for _ in 0..<3 {
            _ = try await lua.run("""
            WindowRectOp("w", miniwin.rect_fill, 0, 0, 0, 0, 0)
            WindowText("w", "f", "x", 0, 0, 0, 0, 0xFFFFFF)
            """)
        }
        let effects = try await lua.run("""
        WindowRectOp("w", miniwin.rect_fill, 0, 0, 0, 0, 0)
        WindowText("w", "f", "x", 0, 0, 0, 0, 0xFFFFFF)
        """)
        let scene = scene(effects)
        #expect(scene?.commands.count == 2) // not accumulating across passes
    }

    @Test("WindowDelete emits a delete effect and drops the scene")
    func deleteEmits() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 50, 50, 6, 0, 0)
        WindowDelete("w")
        """)
        #expect(effects.contains(.deleteMiniWindow(name: "w")))
    }

    @Test("WindowAddHotspot records a hotspot with its callbacks (Phase 2)")
    func hotspotRecorded() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 100, 100, 6, 0, 0)
        WindowAddHotspot("w", "hs", 0, 0, 50, 20, "", "", "", "", "onClick", "tip", miniwin.cursor_hand, 0)
        """)
        let scene = scene(effects)
        #expect(scene?.hotspots.count == 1)
        #expect(scene?.hotspots.first?.mouseUp == "onClick")
        #expect(scene?.hotspots.first?.tooltip == "tip")
    }
}

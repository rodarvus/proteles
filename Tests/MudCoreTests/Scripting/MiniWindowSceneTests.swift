import CoreGraphics
@testable import MudCore
import Testing

@Suite("MiniWindow — scene value-type helpers")
struct MiniWindowSceneTests {
    @Test("fix() resolves zero/negative right/bottom relative to the extent")
    func fixCoordinates() {
        // MUSHclient FixRight/FixBottom: <= 0 is relative to the far edge.
        #expect(MiniWindowScene.fix(0, extent: 200) == 200) // full width (the clear idiom)
        #expect(MiniWindowScene.fix(-1, extent: 200) == 199) // one pixel inside
        #expect(MiniWindowScene.fix(50, extent: 200) == 50) // positive is literal
    }

    @Test("origin() honours the MUSHclient position constants")
    func positionConstants() {
        let container = CGSize(width: 1000, height: 600)
        func origin(_ position: Int) -> CGPoint {
            MiniWindowScene(name: "w", pluginID: "p", width: 200, height: 100, position: position)
                .origin(in: container)
        }
        #expect(origin(4) == .zero) // top-left
        #expect(origin(6) == CGPoint(x: 800, y: 0)) // top-right
        #expect(origin(8) == CGPoint(x: 800, y: 500)) // bottom-right
        #expect(origin(12) == CGPoint(x: 400, y: 250)) // centre-all
    }

    @Test("origin() uses absolute (left, top) when create_absolute_location is set")
    func absoluteLocation() {
        let scene = MiniWindowScene(
            name: "w",
            pluginID: "p",
            width: 200,
            height: 100,
            left: 33,
            top: 44,
            position: 6,
            flags: MiniWindowScene.flagAbsoluteLocation
        )
        #expect(scene.origin(in: CGSize(width: 1000, height: 600)) == CGPoint(x: 33, y: 44))
        #expect(scene.createAbsoluteLocation)
    }

    @Test("create flags decode")
    func createFlags() {
        let scene = MiniWindowScene(
            name: "w",
            pluginID: "p",
            flags: MiniWindowScene.flagUnderneath | MiniWindowScene.flagIgnoreMouse
        )
        #expect(scene.createsUnderneath)
        #expect(scene.ignoresMouse)
        #expect(!scene.createAbsoluteLocation)
    }

    @Test("colour int decodes BGR (red low byte); negative is no-colour")
    func colourDecode() {
        // 0x0000FF = pure red (low byte), 0xFF0000 = pure blue (high byte).
        let red = MiniWindowColour.components(0x0000_00FF)
        #expect(red?.red == 1)
        #expect(red?.green == 0)
        #expect(red?.blue == 0)
        let blue = MiniWindowColour.components(0x00FF_0000)
        #expect(blue?.blue == 1)
        #expect(blue?.red == 0)
        #expect(MiniWindowColour.components(-1) == nil)
    }
}

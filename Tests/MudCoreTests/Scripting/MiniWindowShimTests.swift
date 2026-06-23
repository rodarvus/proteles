import CoreGraphics
import Foundation
import ImageIO
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

    @Test("WindowSetZOrder updates WindowInfo slot 22")
    func windowSetZOrderUpdatesInfoSlot() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 100, 100, 0, 0, 0)
        proteles.echo("before:" .. tostring(WindowInfo("w", 22)))
        proteles.echo("set:" .. tostring(WindowSetZOrder("w", 12345)))
        proteles.echo("after:" .. tostring(WindowInfo("w", 22)))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["before:0", "set:0", "after:12345"])
    }

    @Test("WindowGetPixel returns pixels written by WindowSetPixel")
    func windowGetPixelReturnsExplicitSetPixelColour() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 20, 20, 0, 0, 0x010203)
        proteles.echo("background:" .. tostring(WindowGetPixel("w", 2, 3)))
        proteles.echo("set:" .. tostring(WindowSetPixel("w", 2, 3, 0x112233)))
        proteles.echo("pixel:" .. tostring(WindowGetPixel("w", 2, 3)))
        proteles.echo("unknown:" .. tostring(WindowGetPixel("missing", 0, 0)))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["background:66051", "set:0", "pixel:1122867", "unknown:-2"])
    }

    @Test("WindowImageFromWindow registers captured image metadata")
    func windowImageFromWindowRegistersMetadata() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("source", 0, 0, 37, 19, 0, 0, 0)
        WindowCreate("dest", 0, 0, 5, 5, 0, 0, 0)
        proteles.echo("capture:" .. tostring(WindowImageFromWindow("dest", "snap", "source")))
        local images = WindowImageList("dest")
        proteles.echo("list:" .. tostring(images and images[1]))
        proteles.echo("size:" .. tostring(WindowImageInfo("dest", "snap", 2)) .. "x" ..
          tostring(WindowImageInfo("dest", "snap", 3)))
        proteles.echo("missing:" .. tostring(WindowImageFromWindow("dest", "bad", "missing")))
        proteles.echo("constant:" .. tostring(error_code.eNoSuchWindow))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == [
            "capture:0",
            "list:snap",
            "size:37x19",
            "missing:30073",
            "constant:30073"
        ])
    }

    @Test("WindowWrite exports a reloadable miniwindow image")
    func windowWriteExportsReloadableImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("snapshot.png")
        let bmp = directory.appendingPathComponent("snapshot.bmp")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let pngPath = Self.luaString(png.path)
        let bmpPath = Self.luaString(bmp.path)
        let outsidePath = Self.luaString(outside.path)
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 4, 3, 0, 0, 0x010203)
        WindowSetPixel("w", 1, 1, 0x112233)
        proteles.echo("png:" .. tostring(WindowWrite("w", "\(pngPath)")))
        proteles.echo("bmp:" .. tostring(WindowWrite("w", "\(bmpPath)")))
        proteles.echo("bad_ext:" .. tostring(WindowWrite("w", "\(pngPath).txt")))
        proteles.echo("missing:" .. tostring(WindowWrite("missing", "\(pngPath)")))
        proteles.echo("outside:" .. tostring(WindowWrite("w", "\(outsidePath)")))
        WindowLoadImage("w", "saved", "\(pngPath)")
        proteles.echo("size:" .. tostring(WindowImageInfo("w", "saved", 2)) .. "x" ..
          tostring(WindowImageInfo("w", "saved", 3)))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == [
            "png:0",
            "bmp:0",
            "bad_ext:30046",
            "missing:30073",
            "outside:30013",
            "size:4x3"
        ])
        #expect((try? Data(contentsOf: png))?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
        #expect((try? Data(contentsOf: bmp))?.starts(with: [0x42, 0x4D]) == true)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("WindowWrite replays loaded image draws into exported pixels")
    func windowWriteReplaysLoadedImageDraws() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let output = directory.appendingPathComponent("drawn.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let sourcePath = Self.luaString(source.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        WindowCreate("source", 0, 0, 2, 2, 0, 0, 0)
        WindowSetPixel("source", 0, 0, 0x0000ff)
        WindowSetPixel("source", 1, 0, 0x00ff00)
        WindowSetPixel("source", 0, 1, 0xff0000)
        WindowSetPixel("source", 1, 1, 0xffffff)
        proteles.echo("source:" .. tostring(WindowWrite("source", "\(sourcePath)")))
        WindowCreate("dest", 0, 0, 4, 4, 0, 0, 0)
        WindowLoadImage("dest", "img", "\(sourcePath)")
        WindowDrawImage("dest", "img", 1, 1, 0, 0, miniwin.image_copy)
        proteles.echo("drawn:" .. tostring(WindowWrite("dest", "\(outputPath)")))
        WindowLoadImage("dest", "roundtrip", "\(outputPath)")
        proteles.echo("size:" .. tostring(WindowImageInfo("dest", "roundtrip", 2)) .. "x" ..
          tostring(WindowImageInfo("dest", "roundtrip", 3)))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["source:0", "drawn:0", "size:4x4"])
        let pixels = try Self.pngPixels(output)
        #expect(pixels.colour(atX: 1, y: 1) == .init(red: 255, green: 0, blue: 0))
        #expect(pixels.colour(atX: 2, y: 1) == .init(red: 0, green: 255, blue: 0))
        #expect(pixels.colour(atX: 1, y: 2) == .init(red: 0, green: 0, blue: 255))
        #expect(pixels.colour(atX: 2, y: 2) == .init(red: 255, green: 255, blue: 255))
    }

    @Test("WindowImageFromWindow capture can be drawn and filtered before export")
    func capturedWindowImageDrawsAndFilters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capture.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        WindowCreate("source", 0, 0, 2, 1, 0, 0, 0x0a0a0a)
        WindowSetPixel("source", 1, 0, 0x0000ff)
        WindowCreate("dest", 0, 0, 3, 2, 0, 0, 0x000000)
        proteles.echo("capture:" .. tostring(WindowImageFromWindow("dest", "snap", "source")))
        WindowDrawImage("dest", "snap", 0, 0, 0, 0, miniwin.image_copy)
        WindowFilter("dest", 0, 0, 1, 1, miniwin.filter_brightness, 20)
        proteles.echo("write:" .. tostring(WindowWrite("dest", "\(outputPath)")))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["capture:0", "write:0"])
        let pixels = try Self.pngPixels(output)
        #expect(pixels.colour(atX: 0, y: 0) == .init(red: 30, green: 30, blue: 30))
        #expect(pixels.colour(atX: 1, y: 0) == .init(red: 255, green: 0, blue: 0))
    }

    @Test("WindowBlendImage passes opacity into exported image composition")
    func windowBlendImageOpacityAffectsExportedPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("red.png")
        let output = directory.appendingPathComponent("blend.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let sourcePath = Self.luaString(source.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        WindowCreate("source", 0, 0, 1, 1, 0, 0, 0)
        WindowSetPixel("source", 0, 0, 0x0000ff)
        proteles.echo("source:" .. tostring(WindowWrite("source", "\(sourcePath)")))
        WindowCreate("dest", 0, 0, 1, 1, 0, 0, 0xff0000)
        WindowLoadImage("dest", "red", "\(sourcePath)")
        WindowBlendImage("dest", "red", 0, 0, 0, 0, miniwin.blend_normal, 0.5)
        proteles.echo("blend:" .. tostring(WindowWrite("dest", "\(outputPath)")))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["source:0", "blend:0"])
        let colour = try Self.pngPixels(output).colour(atX: 0, y: 0)
        #expect((120...135).contains(colour.red))
        #expect(colour.green == 0)
        #expect((120...135).contains(colour.blue))
    }

    @Test("WindowHotspotInfo reports callbacks and drag metadata")
    func windowHotspotInfoCallbacksAndDragMetadata() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 100, 100, 0, 0, 0)
        WindowAddHotspot(
          "w", "h", 1, 2, 3, 4, "over", "cancelOver", "down",
          "cancelDown", "up", "tip", 12, 34
        )
        WindowDragHandler("w", "h", "dragMove", "dragRelease", 56)
        proteles.echo("hotspot:" .. table.concat({
          WindowHotspotInfo("w", "h", 1), WindowHotspotInfo("w", "h", 2),
          WindowHotspotInfo("w", "h", 3), WindowHotspotInfo("w", "h", 4),
          WindowHotspotInfo("w", "h", 5), WindowHotspotInfo("w", "h", 6),
          WindowHotspotInfo("w", "h", 7), WindowHotspotInfo("w", "h", 8),
          WindowHotspotInfo("w", "h", 9), WindowHotspotInfo("w", "h", 10),
          WindowHotspotInfo("w", "h", 11), WindowHotspotInfo("w", "h", 12),
          WindowHotspotInfo("w", "h", 13), WindowHotspotInfo("w", "h", 14),
          WindowHotspotInfo("w", "h", 15)
        }, ","))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == [
            "hotspot:1,2,3,4,over,cancelOver,down,cancelDown,up,tip,12,34,dragMove,dragRelease,56"
        ])
    }

    @Test("WindowFontInfo uses MUSHclient metric slots")
    func windowFontInfoMUSHclientMetricSlots() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 100, 100, 0, 0, 0)
        WindowFont("w", "f", "Menlo", 12, true, true, true, true)
        proteles.echo("font:" .. table.concat({
          WindowFontInfo("w", "f", 1), WindowFontInfo("w", "f", 2),
          WindowFontInfo("w", "f", 3), WindowFontInfo("w", "f", 4),
          WindowFontInfo("w", "f", 5), WindowFontInfo("w", "f", 6),
          WindowFontInfo("w", "f", 7), WindowFontInfo("w", "f", 8),
          WindowFontInfo("w", "f", 16), WindowFontInfo("w", "f", 17),
          WindowFontInfo("w", "f", 18), WindowFontInfo("w", "f", 21)
        }, ","))
        """)
        let line = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }.first
        let parts = line?
            .replacingOccurrences(of: "font:", with: "")
            .split(separator: ",")
            .map(String.init) ?? []
        #expect(parts.count == 12)
        #expect(Double(parts[0]) ?? 0 > 0)
        #expect(Double(parts[1]) ?? 0 > 0)
        #expect(Double(parts[2]) ?? 0 > 0)
        #expect(parts[3] == "0")
        #expect(Double(parts[5]) ?? 0 > 0)
        #expect(Double(parts[6]) ?? 0 > 0)
        #expect(parts[7] == "700")
        #expect(parts[8] == "1")
        #expect(parts[9] == "1")
        #expect(parts[10] == "1")
        #expect(parts[11] == "Menlo")
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

    private static func luaString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func pngPixels(_ url: URL) throws -> TestPixels {
        let data = try Data(contentsOf: url)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TestImageError.decodeFailed }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.decodeFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return TestPixels(width: image.width, bytes: bytes)
    }

    private struct TestPixels {
        var width: Int
        var bytes: [UInt8]

        func colour(atX x: Int, y: Int) -> TestColour {
            let index = (y * width + x) * 4
            return TestColour(
                red: Int(bytes[index]),
                green: Int(bytes[index + 1]),
                blue: Int(bytes[index + 2])
            )
        }
    }

    private struct TestColour: Equatable {
        var red: Int
        var green: Int
        var blue: Int
    }

    private enum TestImageError: Error {
        case decodeFailed
    }
}

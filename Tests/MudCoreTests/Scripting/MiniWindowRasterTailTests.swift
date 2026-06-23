import CoreGraphics
import Foundation
import ImageIO
@testable import MudCore
import Testing

@Suite("MiniWindow — raster compatibility tail")
struct MiniWindowRasterTailTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("WindowLoadImageMemory preserves raw PNG bytes with NULs")
    func windowLoadImageMemoryPreservesRawBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("raw-memory.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        local png = string.char(
          137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,
          31,21,196,137,0,0,0,13,73,68,65,84,120,218,99,252,207,192,80,15,0,5,131,
          2,127,148,61,17,79,0,0,0,0,73,69,78,68,174,66,96,130
        )
        WindowCreate("w", 0, 0, 1, 1, 0, 0, 0)
        WindowLoadImageMemory("w", "raw", png)
        proteles.echo("size:" .. tostring(WindowImageInfo("w", "raw", 2)) .. "x" ..
          tostring(WindowImageInfo("w", "raw", 3)))
        WindowDrawImage("w", "raw", 0, 0, 0, 0, miniwin.image_copy)
        proteles.echo("write:" .. tostring(WindowWrite("w", "\(outputPath)")))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["size:1x1", "write:0"])
        #expect((try? Data(contentsOf: output))?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
    }

    @Test("WindowImageOp creates drawable generated images")
    func windowImageOpCreatesDrawableImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("image-op.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 3, 2, 0, 0, 0)
        WindowImageOp("w", miniwin.image_fill_rectangle, 0, 0, 2, 2, 0, 0, 0, 0x0000ff, "generated", 0, 0)
        proteles.echo("size:" .. tostring(WindowImageInfo("w", "generated", 2)) .. "x" ..
          tostring(WindowImageInfo("w", "generated", 3)))
        WindowDrawImage("w", "generated", 1, 0, 0, 0, miniwin.image_copy)
        proteles.echo("write:" .. tostring(WindowWrite("w", "\(outputPath)")))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["size:2x2", "write:0"])
        let pixels = try Self.pngPixels(output)
        #expect(pixels.colour(atX: 1, y: 0) == .init(red: 255, green: 0, blue: 0))
        #expect(pixels.colour(atX: 2, y: 1) == .init(red: 255, green: 0, blue: 0))
    }

    @Test("WindowMergeImageAlpha uses a captured mask during export")
    func windowMergeImageAlphaUsesCapturedMask() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("merge-alpha.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        WindowCreate("maskwin", 0, 0, 2, 1, 0, 0, 0x000000)
        WindowSetPixel("maskwin", 0, 0, 0xffffff)
        WindowCreate("w", 0, 0, 2, 1, 0, 0, 0x000000)
        WindowImageOp("w", miniwin.image_fill_rectangle, 0, 0, 2, 1, 0, 0, 0, 0x0000ff, "red", 0, 0)
        WindowImageFromWindow("w", "mask", "maskwin")
        WindowMergeImageAlpha("w", "red", "mask", 0, 0, 2, 1, miniwin.merge_straight, 1, 0, 0, 0, 0)
        proteles.echo("write:" .. tostring(WindowWrite("w", "\(outputPath)")))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["write:0"])
        let pixels = try Self.pngPixels(output)
        #expect(pixels.colour(atX: 0, y: 0) == .init(red: 255, green: 0, blue: 0))
        #expect(pixels.colour(atX: 1, y: 0) == .init(red: 0, green: 0, blue: 0))
    }

    @Test("WindowTransformImage replays simple scale transforms in exported images")
    func windowTransformImageSimpleScaleExports() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("transform.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 3, 3, 0, 0, 0x000000)
        WindowImageOp("w", miniwin.image_fill_rectangle, 0, 0, 1, 1, 0, 0, 0, 0x0000ff, "red", 0, 0)
        WindowTransformImage("w", "red", 1, 1, miniwin.image_stretch, 2, 0, 0, 2)
        proteles.echo("write:" .. tostring(WindowWrite("w", "\(outputPath)")))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["write:0"])
        let pixels = try Self.pngPixels(output)
        #expect(pixels.colour(atX: 1, y: 1) == .init(red: 255, green: 0, blue: 0))
        #expect(pixels.colour(atX: 2, y: 2) == .init(red: 255, green: 0, blue: 0))
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

import CoreGraphics
import Foundation
import ImageIO
@testable import MudCore
import Testing

@Suite("MiniWindow — return codes and resize fidelity")
struct MiniWindowReturnAndResizeTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("mutating miniwindow calls return eOK for check.lua wrappers")
    func mutatingMiniWindowCallsReturnEOK() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        local check = require "check"
        local ok, err = pcall(function()
          check(WindowCreate("w", 0, 0, 20, 20, 0, 0, 0))
          check(WindowPosition("w", 1, 2, miniwin.pos_top_left, 2))
          check(WindowResize("w", 24, 22, 0x202020))
          check(WindowFont("w", "f", "Menlo", 10))
          check(WindowRectOp("w", miniwin.rect_fill, 0, 0, 0, 0, 0x010101))
          check(WindowCircleOp("w", miniwin.circle_ellipse, 1, 1, 8, 8, 0x0000ff, 0, 1, 0x00ff00, 0))
          check(WindowLine("w", 0, 0, 3, 3, 0xffffff, 0, 1))
          check(WindowGradient("w", 0, 0, 8, 4, 0x000000, 0xffffff, miniwin.gradient_horizontal))
          check(WindowPolygon("w", "0,0, 4,0, 0,4", 0xffffff, 0, 1, 0x000000, 0, true, false))
          check(WindowArc("w", 0, 0, 8, 8, 0, 0, 8, 8, 0xffffff, 0, 1))
          check(WindowBezier("w", "0,0, 2,4, 4,4, 8,0", 0xffffff, 0, 1))
          check(WindowDelete("w"))
        end)
        proteles.echo("ok:" .. tostring(ok) .. ":" .. tostring(err == nil))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["ok:true:true"])
    }

    @Test("WindowResize keeps old surface pixels and fills newly exposed area")
    func windowResizeCopiesOldSurfaceAndFillsNewArea() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("resized.png")

        let lua = try await shimmed()
        await lua.setSQLiteDirectory(directory.path)
        let outputPath = Self.luaString(output.path)
        let effects = try await lua.run("""
        WindowCreate("w", 0, 0, 2, 2, 0, 0, 0xff0000)
        WindowSetPixel("w", 1, 1, 0x0000ff)
        WindowResize("w", 4, 3, 0x00ff00)
        proteles.echo("size:" .. WindowInfo("w", 3) .. "x" .. WindowInfo("w", 4))
        proteles.echo("write:" .. tostring(WindowWrite("w", "\(outputPath)")))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["size:4x3", "write:0"])
        let pixels = try Self.pngPixels(output)
        #expect(pixels.colour(atX: 0, y: 0) == .init(red: 0, green: 0, blue: 255))
        #expect(pixels.colour(atX: 1, y: 1) == .init(red: 255, green: 0, blue: 0))
        #expect(pixels.colour(atX: 3, y: 2) == .init(red: 0, green: 255, blue: 0))
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

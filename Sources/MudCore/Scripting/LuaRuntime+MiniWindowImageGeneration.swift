import CoreGraphics
import Foundation
import ImageIO

struct MiniWindowShapeImageSpec {
    var width: Int
    var height: Int
    var action: Int
    var penColour: Int
    var penStyle: Int
    var penWidth: Int
    var brushColour: Int
    var ellipseWidth: Int
    var ellipseHeight: Int

    var size: MiniWindowRasterSize {
        .init(width: width, height: height)
    }

    var geometry: MiniWindowShapeGeometry {
        .init(size: size, action: action, ellipseWidth: ellipseWidth, ellipseHeight: ellipseHeight)
    }
}

struct MiniWindowShapeGeometry {
    var size: MiniWindowRasterSize
    var action: Int
    var ellipseWidth: Int
    var ellipseHeight: Int
}

struct MiniWindowRoundedRect {
    var size: MiniWindowRasterSize
    var radiusX: Int
    var radiusY: Int
}

extension LuaRuntime {
    nonisolated func createMiniWindowImage(_ name: String, _ arguments: [LuaValue]) -> LuaValue {
        let imageID = Self.argString(arguments, 1)
        guard miniWindows[name] != nil else { return .number(30073) }
        guard !imageID.isEmpty else { return .number(0) }
        let rows = (0..<8).map { Int(Self.argDouble(arguments, $0 + 2)) }
        guard let data = Self.generatedMonochromeImageData(rows: rows) else { return .number(0) }
        storeMiniWindowImage(name: name, imageID: imageID, data: data, width: 8, height: 8)
        return .number(0)
    }

    nonisolated func copyMiniWindowImageAlphaToWindow(_ name: String, _ arguments: [LuaValue]) -> LuaValue {
        let imageID = Self.argString(arguments, 1)
        guard let scene = miniWindows[name] else { return .number(30073) }
        guard let data = miniWindowImageData[name]?[imageID],
              let image = MiniWindowRasterImage(data: data)
        else { return .number(30068) }
        let target = alphaTargetRect(scene: scene, arguments: arguments)
        guard target.width > 0, target.height > 0 else { return .number(0) }
        let srcLeft = max(0, Int(Self.argDouble(arguments, 6)))
        let srcTop = max(0, Int(Self.argDouble(arguments, 7)))
        guard let alpha = Self.alphaImageData(source: image, target: target, srcLeft: srcLeft, srcTop: srcTop)
        else { return .number(0) }
        let alphaID = "__proteles_alpha_\(imageID)"
        storeMiniWindowImage(
            name: name,
            imageID: alphaID,
            data: alpha,
            width: target.width,
            height: target.height
        )
        appendMiniWindowCommand(name, .image(
            imageID: alphaID,
            left: target.x,
            top: target.y,
            right: target.x + target.width,
            bottom: target.y + target.height,
            mode: 1,
            opacity: 1,
            srcLeft: 0,
            srcTop: 0,
            srcRight: 0,
            srcBottom: 0
        ))
        return .number(0)
    }

    nonisolated func storeMiniWindowImage(
        name: String,
        imageID: String,
        data: Data,
        width: Int,
        height: Int
    ) {
        miniWindowImageData[name, default: [:]][imageID] = data
        updateMiniWindow(name) { scene in
            scene.images[imageID] = MiniWindowImageInfo(id: imageID, width: width, height: height)
        }
        effects.append(.loadMiniWindowImage(pluginID: pluginContext.pluginID, imageID: imageID, data: data))
    }

    nonisolated static func generatedShapeImageData(_ spec: MiniWindowShapeImageSpec) -> Data? {
        guard spec.width > 0, spec.height > 0 else { return nil }
        var pixels = Array(
            repeating: MiniWindowRasterPixel(r: 0, g: 0, b: 0, alpha: 0),
            count: spec.width * spec.height
        )
        let fill = MiniWindowRasterPixel.bgr(spec.brushColour)
        let pen = MiniWindowRasterPixel.bgr(spec.penColour)
        let strokeWidth = spec.penStyle == 5 ? 0 : max(0, spec.penWidth)
        for y in 0..<spec.height {
            for x in 0..<spec.width where shapeContains(
                x: x,
                y: y,
                geometry: spec.geometry
            ) {
                let index = y * spec.width + x
                pixels[index] = fill
                if strokeWidth > 0, shapeBorder(
                    x: x,
                    y: y,
                    size: spec.size,
                    strokeWidth: strokeWidth
                ) {
                    pixels[index] = pen
                }
            }
        }
        return pngData(width: spec.width, height: spec.height, pixels: pixels)
    }

    private nonisolated func alphaTargetRect(
        scene: MiniWindowScene,
        arguments: [LuaValue]
    ) -> MiniWindowRasterRect {
        let left = max(0, Int(Self.argDouble(arguments, 2)))
        let top = max(0, Int(Self.argDouble(arguments, 3)))
        let right = min(
            scene.width,
            Int(MiniWindowScene.fix(Int(Self.argDouble(arguments, 4)), extent: scene.width))
        )
        let bottom = min(
            scene.height,
            Int(MiniWindowScene.fix(Int(Self.argDouble(arguments, 5)), extent: scene.height))
        )
        return MiniWindowRasterRect(
            x: left,
            y: top,
            width: max(0, right - left),
            height: max(0, bottom - top)
        )
    }

    private nonisolated static func generatedMonochromeImageData(rows: [Int]) -> Data? {
        var pixels = Array(repeating: MiniWindowRasterPixel(r: 0, g: 0, b: 0, alpha: 0), count: 64)
        for y in 0..<8 {
            let row = y < rows.count ? rows[y] : 0
            for x in 0..<8 where row & (1 << (7 - x)) != 0 {
                pixels[y * 8 + x] = MiniWindowRasterPixel(r: 255, g: 255, b: 255, alpha: 255)
            }
        }
        return pngData(width: 8, height: 8, pixels: pixels)
    }

    private nonisolated static func alphaImageData(
        source: MiniWindowRasterImage,
        target: MiniWindowRasterRect,
        srcLeft: Int,
        srcTop: Int
    ) -> Data? {
        var pixels = Array(
            repeating: MiniWindowRasterPixel(r: 0, g: 0, b: 0),
            count: target.width * target.height
        )
        for y in 0..<target.height {
            for x in 0..<target.width {
                let sx = srcLeft + x
                let sy = srcTop + y
                let alpha: UInt8 = if sx >= 0, sx < source.width, sy >= 0, sy < source.height {
                    source.pixel(x: sx, y: sy).alpha
                } else {
                    0
                }
                pixels[y * target.width + x] = MiniWindowRasterPixel(r: alpha, g: alpha, b: alpha)
            }
        }
        return pngData(width: target.width, height: target.height, pixels: pixels)
    }

    private nonisolated static func shapeContains(
        x: Int,
        y: Int,
        geometry: MiniWindowShapeGeometry
    ) -> Bool {
        switch geometry.action {
        case 1:
            ellipseContains(x: x, y: y, size: geometry.size)
        case 3:
            roundedRectContains(
                x: x,
                y: y,
                shape: .init(
                    size: geometry.size,
                    radiusX: max(1, geometry.ellipseWidth / 2),
                    radiusY: max(1, geometry.ellipseHeight / 2)
                )
            )
        default:
            true
        }
    }

    private nonisolated static func ellipseContains(x: Int, y: Int, size: MiniWindowRasterSize) -> Bool {
        let nx = (Double(x) + 0.5 - Double(size.width) / 2) / max(1, Double(size.width) / 2)
        let ny = (Double(y) + 0.5 - Double(size.height) / 2) / max(1, Double(size.height) / 2)
        return nx * nx + ny * ny <= 1
    }

    private nonisolated static func roundedRectContains(
        x: Int,
        y: Int,
        shape: MiniWindowRoundedRect
    ) -> Bool {
        let rx = min(shape.radiusX, max(1, shape.size.width / 2))
        let ry = min(shape.radiusY, max(1, shape.size.height / 2))
        let cx = x < rx ? rx : (x >= shape.size.width - rx ? shape.size.width - rx - 1 : x)
        let cy = y < ry ? ry : (y >= shape.size.height - ry ? shape.size.height - ry - 1 : y)
        let nx = (Double(x - cx) + 0.5) / max(1, Double(rx))
        let ny = (Double(y - cy) + 0.5) / max(1, Double(ry))
        return nx * nx + ny * ny <= 1
    }

    private nonisolated static func shapeBorder(
        x: Int,
        y: Int,
        size: MiniWindowRasterSize,
        strokeWidth: Int
    ) -> Bool {
        x < strokeWidth || y < strokeWidth || x >= size.width - strokeWidth || y >= size.height - strokeWidth
    }

    private nonisolated static func pngData(
        width: Int,
        height: Int,
        pixels: [MiniWindowRasterPixel]
    ) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for pixel in pixels {
            bytes.append(pixel.r)
            bytes.append(pixel.g)
            bytes.append(pixel.b)
            bytes.append(pixel.alpha)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

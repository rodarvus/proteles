import CoreGraphics
import Foundation
import ImageIO

extension LuaRuntime {
    /// `WindowWrite(name, filename)` — export a raster snapshot of the retained
    /// scene, including loaded/captured images and the common filter/blend path
    /// used by Aardwolf's MUSHclient theme generator.
    nonisolated func writeMiniWindowImage(_ name: String, _ arguments: [LuaValue]) -> LuaValue {
        guard let scene = miniWindows[name] else { return .number(30073) }
        let path = Self.argString(arguments, 1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .number(30003) }
        guard path.count >= 5 else { return .number(30046) }
        let lowercased = path.lowercased()
        guard scene.width > 0, scene.height > 0 else { return .number(30046) }

        let data: Data?
        if lowercased.hasSuffix(".png") {
            data = miniWindowPNGData(scene)
        } else if lowercased.hasSuffix(".bmp") {
            data = miniWindowBMPData(scene)
        } else {
            return .number(30046)
        }
        guard let data, writeFileDataAllowed(path, data) else { return .number(30013) }
        return .number(0)
    }

    nonisolated func miniWindowPNGData(_ scene: MiniWindowScene) -> Data? {
        guard let image = miniWindowCGImage(scene) else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private nonisolated func miniWindowBMPData(_ scene: MiniWindowScene) -> Data {
        let rowBytes = ((scene.width * 3) + 3) & ~3
        let pixelBytes = rowBytes * scene.height
        var data = Data()
        appendLE16(0x4D42, to: &data)
        appendLE32(UInt32(14 + 40 + pixelBytes), to: &data)
        appendLE16(0, to: &data)
        appendLE16(0, to: &data)
        appendLE32(54, to: &data)
        appendLE32(40, to: &data)
        appendLE32(UInt32(scene.width), to: &data)
        appendLE32(UInt32(scene.height), to: &data)
        appendLE16(1, to: &data)
        appendLE16(24, to: &data)
        appendLE32(0, to: &data)
        appendLE32(UInt32(pixelBytes), to: &data)
        appendLE32(0, to: &data)
        appendLE32(0, to: &data)
        appendLE32(0, to: &data)
        appendLE32(0, to: &data)

        let pixels = miniWindowBGRRows(scene)
        let padding = [UInt8](repeating: 0, count: rowBytes - scene.width * 3)
        for y in stride(from: scene.height - 1, through: 0, by: -1) {
            data.append(contentsOf: pixels[y])
            data.append(contentsOf: padding)
        }
        return data
    }

    private nonisolated func miniWindowCGImage(_ scene: MiniWindowScene) -> CGImage? {
        let rgba = miniWindowRGBABytes(scene)
        let providerData = Data(rgba) as CFData
        guard
            let provider = CGDataProvider(data: providerData),
            let image = CGImage(
                width: scene.width,
                height: scene.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: scene.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }
        return image
    }

    private nonisolated func miniWindowRGBABytes(_ scene: MiniWindowScene) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scene.width * scene.height * 4)
        for row in miniWindowBGRRows(scene) {
            for index in stride(from: 0, to: row.count, by: 3) {
                bytes.append(row[index + 2])
                bytes.append(row[index + 1])
                bytes.append(row[index])
                bytes.append(255)
            }
        }
        return bytes
    }

    private nonisolated func miniWindowBGRRows(_ scene: MiniWindowScene) -> [[UInt8]] {
        let background = MiniWindowRasterPixel.bgr(scene.backgroundColour)
        var rows = Array(repeating: Array(repeating: background, count: scene.width), count: scene.height)
        replayMiniWindowCommands(scene.commands, windowName: scene.name, rows: &rows)
        return rows.map { row in
            var bytes: [UInt8] = []
            bytes.reserveCapacity(scene.width * 3)
            for pixel in row {
                bytes.append(contentsOf: [pixel.b, pixel.g, pixel.r])
            }
            return bytes
        }
    }

    private nonisolated func replayMiniWindowCommands(
        _ commands: [MiniWindowCommand],
        windowName: String,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        for command in commands {
            switch command {
            case .rect(let action, let left, let top, let right, let bottom, let colour, _):
                let bounds = MiniWindowRasterBounds(left: left, top: top, right: right, bottom: bottom)
                if action != 1 { fill(rect(bounds, rows), colour: colour, rows: &rows) }
            case .setPixel(let x, let y, let colour):
                setPixel(x, y, MiniWindowRasterPixel.bgr(colour), rows: &rows)
            case .image(
                let id,
                let left,
                let top,
                let right,
                let bottom,
                let mode,
                let opacity,
                let sl,
                let st,
                let sr,
                let sb
            ):
                drawImage(.init(
                    imageID: id,
                    windowName: windowName,
                    target: .init(left: left, top: top, right: right, bottom: bottom),
                    source: .init(left: sl, top: st, right: sr, bottom: sb),
                    mode: mode,
                    opacity: opacity
                ), rows: &rows)
            case .filter(let left, let top, let right, let bottom, let operation, let options):
                let bounds = MiniWindowRasterBounds(left: left, top: top, right: right, bottom: bottom)
                filter(
                    rect(bounds, rows),
                    operation: operation,
                    options: options,
                    rows: &rows
                )
            default:
                break
            }
        }
    }

    private nonisolated func drawImage(_ draw: MiniWindowImageDraw, rows: inout [[MiniWindowRasterPixel]]) {
        guard
            let data = miniWindowImageData[draw.windowName]?[draw.imageID],
            let image = MiniWindowRasterImage(data: data)
        else { return }
        let source = image.rect(draw.source)
        let target = targetRect(draw.target, source: source, mode: draw.mode, rows: rows)
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return }
        for y in 0..<target.height {
            let sy = source.y + min(source.height - 1, y * source.height / target.height)
            for x in 0..<target.width {
                let sx = source.x + min(source.width - 1, x * source.width / target.width)
                let dx = target.x + x
                let dy = target.y + y
                guard dy >= 0, dy < rows.count, dx >= 0, dx < rows[dy].count else { continue }
                let sourcePixel = image.pixel(x: sx, y: sy)
                if draw.mode == 3, sourcePixel.matches(image.pixel(x: 0, y: 0)) { continue }
                rows[dy][dx] = sourcePixel.composited(
                    over: rows[dy][dx],
                    mode: draw.mode,
                    opacity: draw.opacity
                )
            }
        }
    }

    private nonisolated func targetRect(
        _ args: MiniWindowRasterBounds,
        source: MiniWindowRasterRect,
        mode: Int,
        rows: [[MiniWindowRasterPixel]]
    ) -> MiniWindowRasterRect {
        let width = rows.first?.count ?? 0
        let height = rows.count
        if mode == 2 {
            return rect(args, rows)
        }
        let maxX = args.right > args.left ? min(args.right, width) : min(args.left + source.width, width)
        let maxY = args.bottom > args.top ? min(args.bottom, height) : min(args.top + source.height, height)
        return MiniWindowRasterRect(
            x: max(0, args.left),
            y: max(0, args.top),
            width: max(0, maxX - args.left),
            height: max(0, maxY - args.top)
        )
    }

    private nonisolated func filter(
        _ rect: MiniWindowRasterRect,
        operation: Int,
        options: Double,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        for y in rect.y..<(rect.y + rect.height) where y >= 0 && y < rows.count {
            for x in rect.x..<(rect.x + rect.width) where x >= 0 && x < rows[y].count {
                rows[y][x] = rows[y][x].filtered(operation: operation, options: options)
            }
        }
    }

    private nonisolated func fill(
        _ rect: MiniWindowRasterRect,
        colour: Int,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        let pixel = MiniWindowRasterPixel.bgr(colour)
        for y in rect.y..<(rect.y + rect.height) where y >= 0 && y < rows.count {
            for x in rect.x..<(rect.x + rect.width) where x >= 0 && x < rows[y].count {
                rows[y][x] = pixel
            }
        }
    }

    private nonisolated func setPixel(
        _ x: Int,
        _ y: Int,
        _ pixel: MiniWindowRasterPixel,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        guard y >= 0, y < rows.count, x >= 0, x < rows[y].count else { return }
        rows[y][x] = pixel
    }

    private nonisolated func rect(
        _ bounds: MiniWindowRasterBounds,
        _ rows: [[MiniWindowRasterPixel]]
    ) -> MiniWindowRasterRect {
        let width = rows.first?.count ?? 0
        let height = rows.count
        let fixedRight = Int(MiniWindowScene.fix(bounds.right, extent: width))
        let fixedBottom = Int(MiniWindowScene.fix(bounds.bottom, extent: height))
        let x = max(0, bounds.left)
        let y = max(0, bounds.top)
        return MiniWindowRasterRect(
            x: x,
            y: y,
            width: max(0, min(width, fixedRight) - x),
            height: max(0, min(height, fixedBottom) - y)
        )
    }

    nonisolated static func clampedOpacity(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private nonisolated func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private nonisolated func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

private struct MiniWindowRasterRect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

private struct MiniWindowRasterBounds {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int
}

private struct MiniWindowImageDraw {
    var imageID: String
    var windowName: String
    var target: MiniWindowRasterBounds
    var source: MiniWindowRasterBounds
    var mode: Int
    var opacity: Double
}

private struct MiniWindowRasterImage {
    let width: Int
    let height: Int
    let pixels: [MiniWindowRasterPixel]

    init?(data: Data) {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        width = cgImage.width
        height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = stride(from: 0, to: bytes.count, by: 4).map {
            MiniWindowRasterPixel(r: bytes[$0], g: bytes[$0 + 1], b: bytes[$0 + 2], alpha: bytes[$0 + 3])
        }
    }

    func rect(_ bounds: MiniWindowRasterBounds) -> MiniWindowRasterRect {
        let fixedRight = bounds.right <= 0 ? width + bounds.right : min(width, bounds.right)
        let fixedBottom = bounds.bottom <= 0 ? height + bounds.bottom : min(height, bounds.bottom)
        let x = max(0, bounds.left)
        let y = max(0, bounds.top)
        return MiniWindowRasterRect(
            x: x,
            y: y,
            width: max(0, fixedRight - x),
            height: max(0, fixedBottom - y)
        )
    }

    func pixel(x: Int, y: Int) -> MiniWindowRasterPixel {
        pixels[y * width + x]
    }
}

private struct MiniWindowRasterPixel {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var alpha: UInt8 = 255

    static func bgr(_ colour: Int) -> Self {
        Self(
            r: UInt8(clamping: colour & 0xFF),
            g: UInt8(clamping: (colour >> 8) & 0xFF),
            b: UInt8(clamping: (colour >> 16) & 0xFF)
        )
    }

    func matches(_ other: Self) -> Bool {
        r == other.r && g == other.g && b == other.b
    }

    func composited(over base: Self, mode: Int, opacity: Double) -> Self {
        let adjustedAlpha = Double(alpha) / 255 * opacity
        return Self(
            r: blendChannel(r, over: base.r, mode: mode, alpha: adjustedAlpha),
            g: blendChannel(g, over: base.g, mode: mode, alpha: adjustedAlpha),
            b: blendChannel(b, over: base.b, mode: mode, alpha: adjustedAlpha)
        )
    }

    func filtered(operation: Int, options: Double) -> Self {
        switch operation {
        case 7:
            return map { clamp(Double($0) + options) }
        case 8:
            let factor = (259 * (options + 255)) / (255 * (259 - options))
            return map { clamp(factor * (Double($0) - 128) + 128) }
        case 9:
            let gamma = max(0.01, options)
            return map { clamp(255 * pow(Double($0) / 255, 1 / gamma)) }
        case 19, 20:
            let gray = UInt8(clamping: Int(0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)))
            return Self(r: gray, g: gray, b: gray, alpha: alpha)
        case 21:
            return map { clamp(Double($0) * options) }
        default:
            return self
        }
    }

    private func map(_ transform: (UInt8) -> UInt8) -> Self {
        Self(r: transform(r), g: transform(g), b: transform(b), alpha: alpha)
    }

    private func blendChannel(_ source: UInt8, over base: UInt8, mode: Int, alpha: Double) -> UInt8 {
        let sourceValue = Double(source)
        let baseValue = Double(base)
        let blended: Double = switch mode {
        case 5: min(sourceValue, baseValue) // darken
        case 6: sourceValue * baseValue / 255 // multiply
        case 12: 255 - ((255 - sourceValue) * (255 - baseValue) / 255) // screen
        case 21: clampDouble(baseValue + 2 * sourceValue - 255) // linear light
        default: sourceValue
        }
        return clamp((blended * alpha) + (baseValue * (1 - alpha)))
    }

    private func clamp(_ value: Double) -> UInt8 {
        UInt8(clamping: Int(value.rounded()))
    }

    private func clampDouble(_ value: Double) -> Double {
        min(255, max(0, value))
    }
}

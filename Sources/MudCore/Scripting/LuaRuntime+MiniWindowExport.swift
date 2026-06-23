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
            replayMiniWindowCommand(command, windowName: windowName, rows: &rows)
        }
    }

    private nonisolated func replayMiniWindowCommand(
        _ command: MiniWindowCommand,
        windowName: String,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        switch command {
        case .rect(let action, let left, let top, let right, let bottom, let colour, _):
            let bounds = MiniWindowRasterBounds(left: left, top: top, right: right, bottom: bottom)
            if action != 1 { fill(rect(bounds, rows), colour: colour, rows: &rows) }
        case .setPixel(let x, let y, let colour):
            setPixel(x, y, MiniWindowRasterPixel.bgr(colour), rows: &rows)
        case .filter(let left, let top, let right, let bottom, let operation, let options):
            let bounds = MiniWindowRasterBounds(left: left, top: top, right: right, bottom: bottom)
            filter(rect(bounds, rows), operation: operation, options: options, rows: &rows)
        default:
            replayMiniWindowImageCommand(command, windowName: windowName, rows: &rows)
        }
    }

    private nonisolated func replayMiniWindowImageCommand(
        _ command: MiniWindowCommand,
        windowName: String,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        switch command {
        case .image:
            replayPlainImageCommand(command, windowName: windowName, rows: &rows)
        case .imageMask:
            replayMaskedImageCommand(command, windowName: windowName, rows: &rows)
        case .transformedImage(let id, let left, let top, let mode, let mxx, let mxy, let myx, let myy):
            let draw = MiniWindowTransformDraw(
                imageID: id,
                windowName: windowName,
                left: left,
                top: top,
                mode: mode,
                mxx: mxx,
                mxy: mxy,
                myx: myx,
                myy: myy
            )
            drawTransformedImage(draw, rows: &rows)
        default:
            break
        }
    }

    private nonisolated func replayPlainImageCommand(
        _ command: MiniWindowCommand,
        windowName: String,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        guard case .image(
            let imageID,
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
        ) = command else { return }
        drawImage(
            MiniWindowImageDraw(
                imageID: imageID,
                windowName: windowName,
                target: .init(left: left, top: top, right: right, bottom: bottom),
                source: .init(left: sl, top: st, right: sr, bottom: sb),
                mode: mode,
                opacity: opacity
            ),
            rows: &rows
        )
    }

    private nonisolated func replayMaskedImageCommand(
        _ command: MiniWindowCommand,
        windowName: String,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        guard case .imageMask(
            let imageID,
            let maskID,
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
        ) = command else { return }
        drawMaskedImage(
            MiniWindowImageDraw(
                imageID: imageID,
                windowName: windowName,
                target: .init(left: left, top: top, right: right, bottom: bottom),
                source: .init(left: sl, top: st, right: sr, bottom: sb),
                mode: mode,
                opacity: opacity
            ),
            maskID: maskID,
            rows: &rows
        )
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

    private nonisolated func drawMaskedImage(
        _ draw: MiniWindowImageDraw,
        maskID: String,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        guard
            let data = miniWindowImageData[draw.windowName]?[draw.imageID],
            let maskData = miniWindowImageData[draw.windowName]?[maskID],
            let image = MiniWindowRasterImage(data: data),
            let mask = MiniWindowRasterImage(data: maskData)
        else { return }
        let source = image.rect(draw.source)
        let target = targetRect(draw.target, source: source, mode: 2, rows: rows)
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return }
        for y in 0..<target.height {
            let sy = source.y + min(source.height - 1, y * source.height / target.height)
            let my = min(mask.height - 1, y * mask.height / target.height)
            for x in 0..<target.width {
                let sx = source.x + min(source.width - 1, x * source.width / target.width)
                let mx = min(mask.width - 1, x * mask.width / target.width)
                let dx = target.x + x
                let dy = target.y + y
                guard dy >= 0, dy < rows.count, dx >= 0, dx < rows[dy].count else { continue }
                let sourcePixel = image.pixel(x: sx, y: sy)
                let maskPixel = mask.pixel(x: mx, y: my)
                if draw.mode == 1, sourcePixel.matches(image.pixel(x: 0, y: 0)) { continue }
                let maskOpacity = Double(maskPixel.alpha) / 255 * maskPixel.luminance
                rows[dy][dx] = sourcePixel.composited(
                    over: rows[dy][dx],
                    mode: 1,
                    opacity: draw.opacity * maskOpacity
                )
            }
        }
    }

    private nonisolated func drawTransformedImage(
        _ draw: MiniWindowTransformDraw,
        rows: inout [[MiniWindowRasterPixel]]
    ) {
        guard
            let data = miniWindowImageData[draw.windowName]?[draw.imageID],
            let image = MiniWindowRasterImage(data: data)
        else { return }
        let determinant = draw.mxx * draw.myy - draw.mxy * draw.myx
        guard abs(determinant) > 0.0001 else { return }
        let bounds = transformedBounds(draw: draw, width: image.width, height: image.height)
        for dy in bounds.y..<(bounds.y + bounds.height) where dy >= 0 && dy < rows.count {
            for dx in bounds.x..<(bounds.x + bounds.width) where dx >= 0 && dx < rows[dy].count {
                let localX = Double(dx) + 0.5 - Double(draw.left)
                let localY = Double(dy) + 0.5 - Double(draw.top)
                let sx = (localX * draw.myy - localY * draw.mxy) / determinant
                let sy = (localY * draw.mxx - localX * draw.myx) / determinant
                let ix = Int(sx.rounded(.down))
                let iy = Int(sy.rounded(.down))
                guard ix >= 0, ix < image.width, iy >= 0, iy < image.height else { continue }
                let sourcePixel = image.pixel(x: ix, y: iy)
                if draw.mode == 3, sourcePixel.matches(image.pixel(x: 0, y: 0)) { continue }
                rows[dy][dx] = sourcePixel.composited(over: rows[dy][dx], mode: 1, opacity: 1)
            }
        }
    }

    private nonisolated func transformedBounds(
        draw: MiniWindowTransformDraw,
        width: Int,
        height: Int
    ) -> MiniWindowRasterRect {
        let corners: [(Double, Double)] = [
            (0, 0),
            (Double(width), 0),
            (0, Double(height)),
            (Double(width), Double(height))
        ]
        let points = corners.map {
            (
                x: Double(draw.left) + $0.0 * draw.mxx + $0.1 * draw.mxy,
                y: Double(draw.top) + $0.0 * draw.myx + $0.1 * draw.myy
            )
        }
        let minX = Int(floor(points.map(\.x).min() ?? Double(draw.left)))
        let maxX = Int(ceil(points.map(\.x).max() ?? Double(draw.left)))
        let minY = Int(floor(points.map(\.y).min() ?? Double(draw.top)))
        let maxY = Int(ceil(points.map(\.y).max() ?? Double(draw.top)))
        return MiniWindowRasterRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
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

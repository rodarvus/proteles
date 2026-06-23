import CoreGraphics
import Foundation
import ImageIO

struct MiniWindowRasterRect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct MiniWindowRasterSize {
    var width: Int
    var height: Int
}

struct MiniWindowRasterBounds {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int
}

struct MiniWindowImageDraw {
    var imageID: String
    var windowName: String
    var target: MiniWindowRasterBounds
    var source: MiniWindowRasterBounds
    var mode: Int
    var opacity: Double
}

struct MiniWindowTransformDraw {
    var imageID: String
    var windowName: String
    var left: Int
    var top: Int
    var mode: Int
    var mxx: Double
    var mxy: Double
    var myx: Double
    var myy: Double
}

struct MiniWindowRasterImage {
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
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
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

struct MiniWindowRasterPixel {
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

    var luminance: Double {
        (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
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
            map { clamp(Double($0) + options) }
        case 8:
            map { clamp(((259 * (options + 255)) / (255 * (259 - options))) * (Double($0) - 128) + 128) }
        case 9:
            map { clamp(255 * pow(Double($0) / 255, 1 / max(0.01, options))) }
        case 19, 20:
            grayscale()
        case 21:
            map { clamp(Double($0) * options) }
        default:
            self
        }
    }

    private func grayscale() -> Self {
        let gray = UInt8(clamping: Int(0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)))
        return Self(r: gray, g: gray, b: gray, alpha: alpha)
    }

    private func map(_ transform: (UInt8) -> UInt8) -> Self {
        Self(r: transform(r), g: transform(g), b: transform(b), alpha: alpha)
    }

    private func blendChannel(_ source: UInt8, over base: UInt8, mode: Int, alpha: Double) -> UInt8 {
        let sourceValue = Double(source)
        let baseValue = Double(base)
        let blended: Double = switch mode {
        case 5: min(sourceValue, baseValue)
        case 6: sourceValue * baseValue / 255
        case 12: 255 - ((255 - sourceValue) * (255 - baseValue) / 255)
        case 21: clampDouble(baseValue + 2 * sourceValue - 255)
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

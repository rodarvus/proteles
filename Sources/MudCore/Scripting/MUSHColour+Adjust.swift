import Foundation

/// `AdjustColour(colour, method)` — MUSHclient's colour tweaker. Ported verbatim
/// (no guessing) from `AdjustColour` (`Utilities.cpp`) and the `CColor` HLS class
/// (`Color.cpp`), which is the textbook HSL conversion
/// (en.wikipedia.org/wiki/HSL_color_space) with round-half-up (`+ 0.5`, then
/// truncate) on the way back to 8-bit channels. Swift `Double` is IEEE-754 like
/// the C++ `double`, so the result is byte-for-byte identical.
///
/// `method` is the `ADJUST_COLOUR_*` enum (`stdafx.h`): 0 no-op, 1 invert,
/// 2 lighter (+0.02 luminance), 3 darker (-0.02), 4 less colour (-0.05
/// saturation), 5 more colour (+0.05). Anything else returns the input. The
/// colour in/out is a COLORREF (red low byte), as elsewhere in ``MUSHColour``.
extension MUSHColour {
    public static func adjustColour(_ colour: Int, method: Int) -> Int {
        let colourref = colour & 0xFFFFFF
        switch method {
        case 1: // invert
            let red = colourref & 0xFF
            let green = (colourref >> 8) & 0xFF
            let blue = (colourref >> 16) & 0xFF
            return pack(255 - red, 255 - green, 255 - blue)
        case 2: return withLuminance(colourref) { min($0 + 0.02, 1.0) }
        case 3: return withLuminance(colourref) { max($0 - 0.02, 0.0) }
        case 4: return withSaturation(colourref) { max($0 - 0.05, 0.0) }
        case 5: return withSaturation(colourref) { min($0 + 0.05, 1.0) }
        default: return colourref
        }
    }

    /// HLS triple (hue 0…360, luminance/saturation 0…1).
    private struct HLS { var hue: Double; var luminance: Double; var saturation: Double }

    private static func withLuminance(_ colourref: Int, _ transform: (Double) -> Double) -> Int {
        var hls = toHLS(colourref)
        hls.luminance = transform(hls.luminance)
        return toRGB(hls)
    }

    private static func withSaturation(_ colourref: Int, _ transform: (Double) -> Double) -> Int {
        var hls = toHLS(colourref)
        hls.saturation = transform(hls.saturation)
        return toRGB(hls)
    }

    /// `CColor::ToHLS` — RGB COLORREF → HLS.
    private static func toHLS(_ colourref: Int) -> HLS {
        let red = Double(colourref & 0xFF) / 255.0
        let green = Double((colourref >> 8) & 0xFF) / 255.0
        let blue = Double((colourref >> 16) & 0xFF) / 255.0
        let mincolor = min(red, min(green, blue))
        let maxcolor = max(red, max(green, blue))
        let colordiff = maxcolor - mincolor
        // Grey: hue + saturation undefined, luminance is the (equal) channel.
        if colordiff == 0 { return HLS(hue: 0, luminance: mincolor, saturation: 0) }
        let luminance = (maxcolor + mincolor) / 2.0
        var saturation = luminance < 0.5
            ? colordiff / (maxcolor + mincolor)
            : colordiff / (2.0 - (maxcolor + mincolor))
        var hue = if red == maxcolor {
            60.0 * (green - blue) / colordiff
        } else if green == maxcolor {
            60.0 * (blue - red) / colordiff + 120.0
        } else {
            60.0 * (red - green) / colordiff + 240.0
        }
        if hue < 0.0 { hue += 360.0 } else if hue > 360.0 { hue -= 360.0 }
        if saturation > 1.0 { saturation = 1.0 } else if saturation < 0.0 { saturation = 0.0 }
        return HLS(hue: hue, luminance: luminance, saturation: saturation)
    }

    /// `CColor::ToRGB` — HLS → RGB COLORREF (round-half-up to 8-bit channels).
    private static func toRGB(_ hls: HLS) -> Int {
        if hls.saturation <= 0.0 {
            let value = Int(hls.luminance * 255 + 0.5)
            return pack(value, value, value)
        }
        let high = hls.luminance < 0.5
            ? hls.luminance * (1.0 + hls.saturation)
            : (hls.luminance + hls.saturation) - (hls.luminance * hls.saturation)
        let low = 2.0 * hls.luminance - high
        let hk = hls.hue / 360.0
        let red = toRGBComponent(wrap(hk + 1.0 / 3.0), low, high) * 255
        let green = toRGBComponent(wrap(hk), low, high) * 255
        let blue = toRGBComponent(wrap(hk - 1.0 / 3.0), low, high) * 255
        return pack(Int(red + 0.5), Int(green + 0.5), Int(blue + 0.5))
    }

    /// Wrap an HLS hue fraction into [0, 1), as `ToRGB` does to tr/tg/tb.
    private static func wrap(_ fraction: Double) -> Double {
        var value = fraction
        if value < 0.0 { value += 1.0 }
        if value > 1.0 { value -= 1.0 }
        return value
    }

    /// `CColor::ToRGB1` — one channel from the wrapped hue `fraction`, between
    /// the `low` (p) and `high` (q) luminance bounds.
    private static func toRGBComponent(_ fraction: Double, _ low: Double, _ high: Double) -> Double {
        if fraction < 1.0 / 6.0 { return low + ((high - low) * 6.0 * fraction) }
        if fraction < 0.5 { return high }
        if fraction < 2.0 / 3.0 { return low + ((high - low) * 6.0 * (2.0 / 3.0 - fraction)) }
        return low
    }

    /// Pack 8-bit channels into a COLORREF (red low byte) — `RGB()` macro.
    private static func pack(_ red: Int, _ green: Int, _ blue: Int) -> Int {
        (red & 0xFF) | ((green & 0xFF) << 8) | ((blue & 0xFF) << 16)
    }
}

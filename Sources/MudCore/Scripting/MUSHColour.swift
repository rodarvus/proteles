import Foundation

/// MUSHclient colour integers for the trigger `styles` table and the
/// `GetNormalColour`/`GetBoldColour` shim functions. MUSHclient represents a
/// colour as a **BGR** int (red in the low byte) — its `GetNormalColour(n)` /
/// `GetBoldColour(n)` return the world's colour `n` that way, and a trigger
/// style run's `textcolour` is the same int. So a plugin can compare them
/// (`styles[1].textcolour == GetNormalColour(7)`), which is how colour-aware
/// triggers (e.g. social capture) classify a line.
///
/// We give both sides ONE canonical 16-colour ANSI palette (theme-independent,
/// like the world's fixed colours) so the comparison behaves exactly as it does
/// in MUSHclient. The exact RGBs matter less than that both sides agree.
public enum MUSHColour {
    /// Pack an (r, g, b) into MUSHclient's BGR int (red low byte).
    private static func bgr(_ red: Int, _ green: Int, _ blue: Int) -> Int {
        red | (green << 8) | (blue << 16)
    }

    /// Normal (dim) ANSI colours 0…7: black, red, green, yellow, blue,
    /// magenta, cyan, white — the standard VGA/ANSI palette.
    public static let normal: [Int] = [
        bgr(0, 0, 0), bgr(128, 0, 0), bgr(0, 128, 0), bgr(128, 128, 0),
        bgr(0, 0, 128), bgr(128, 0, 128), bgr(0, 128, 128), bgr(192, 192, 192)
    ]

    /// Bold (bright) ANSI colours 0…7.
    public static let bold: [Int] = [
        bgr(128, 128, 128), bgr(255, 0, 0), bgr(0, 255, 0), bgr(255, 255, 0),
        bgr(0, 0, 255), bgr(255, 0, 255), bgr(0, 255, 255), bgr(255, 255, 255)
    ]

    /// The MUSHclient colour int for an ``ANSIColor`` — used for a trigger
    /// style run's `textcolour`/`backcolour`. Named/bright map to the canonical
    /// palette (so they equal `GetNormalColour`/`GetBoldColour`); 24-bit and
    /// 256-colour map to their own BGR value (no named match, as MUSHclient).
    public static func int(for color: ANSIColor) -> Int {
        switch color {
        case .named(let name): normal[Int(name.rawValue)]
        case .brightNamed(let name): bold[Int(name.rawValue)]
        case .rgb(let red, let green, let blue): bgr(Int(red), Int(green), Int(blue))
        case .palette(let index): paletteBGR(index)
        }
    }

    /// 256-colour index → BGR, via the standard xterm cube (matches the
    /// `aardwolf_colors` converter): 0…15 are the ANSI 16, 16…231 the 6×6×6
    /// cube, 232…255 the grayscale ramp.
    private static func paletteBGR(_ index: UInt8) -> Int {
        let value = Int(index)
        if value < 8 { return normal[value] }
        if value < 16 { return bold[value - 8] }
        if value < 232 {
            let cube = value - 16
            func component(_ steps: Int) -> Int {
                steps == 0 ? 0 : steps * 40 + 55
            }
            let red = component((cube / 36) % 6)
            let green = component((cube / 6) % 6)
            let blue = component(cube % 6)
            return bgr(red, green, blue)
        }
        let gray = (value - 232) * 10 + 8
        return bgr(gray, gray, gray)
    }
}

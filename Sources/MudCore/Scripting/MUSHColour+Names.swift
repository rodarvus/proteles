import Foundation

/// The named-colour table behind the `ColourNameToRGB` / `RGBColourToName`
/// world functions. Ported verbatim from MUSHclient (no guessing):
///   - the names + RGBs are `MXP_colours[]` (`mxp/mxpinit.cpp`, lines 127-277) —
///     the W3C/CSS named set, 148 entries, in source order;
///   - the name→int direction is `SetColour` (`mxp/mxputils.cpp`);
///   - the int→name direction is `ColourToName` (`Utilities.cpp`).
///
/// MUSHclient stores its colours as a Windows **COLORREF** (red in the low byte,
/// `0x00BBGGRR`), the same convention as ``MUSHColour/int(for:)``. The source
/// table is written `0xRRGGBB`, which the loader byte-swaps R↔B (its comment:
/// "colours seem to be inverted in my table above"). So `ColourNameToRGB("red")`
/// is `0x0000FF` (255), exactly matching `"#ff0000"` and `GetBoldColour(1)`.
///
/// Two deliberate, documented deviations from the reference, both in degenerate
/// input only (every real `"name"` / `"#rrggbb"` is exact):
///   - MUSHclient resolves an int that aliases several names (`aqua`/`cyan`,
///     `gray`/`grey`, …) via hash order, i.e. non-deterministically. We return
///     the **first name in source order** so the result is stable.
///   - An over-long `#` run returns -1 here; MUSHclient has a quirky partial
///     parse. (`"#"` alone → black in both, matching `SetColour`.)
extension MUSHColour {
    /// `MXP_colours[]` in source order. `rgb` is the source `0xRRGGBB` value;
    /// the COLORREF a script sees is ``swapRedBlue(_:)`` of it.
    static let names: [(name: String, rgb: Int)] = [
        (name: "aliceblue", rgb: 0xF0F8FF),
        (name: "antiquewhite", rgb: 0xFAEBD7),
        (name: "aqua", rgb: 0x00FFFF),
        (name: "aquamarine", rgb: 0x7FFFD4),
        (name: "azure", rgb: 0xF0FFFF),
        (name: "beige", rgb: 0xF5F5DC),
        (name: "bisque", rgb: 0xFFE4C4),
        (name: "black", rgb: 0x000000),
        (name: "blanchedalmond", rgb: 0xFFEBCD),
        (name: "blue", rgb: 0x0000FF),
        (name: "blueviolet", rgb: 0x8A2BE2),
        (name: "brown", rgb: 0xA52A2A),
        (name: "burlywood", rgb: 0xDEB887),
        (name: "cadetblue", rgb: 0x5F9EA0),
        (name: "chartreuse", rgb: 0x7FFF00),
        (name: "chocolate", rgb: 0xD2691E),
        (name: "coral", rgb: 0xFF7F50),
        (name: "cornflowerblue", rgb: 0x6495ED),
        (name: "cornsilk", rgb: 0xFFF8DC),
        (name: "crimson", rgb: 0xDC143C),
        (name: "cyan", rgb: 0x00FFFF),
        (name: "darkblue", rgb: 0x00008B),
        (name: "darkcyan", rgb: 0x008B8B),
        (name: "darkgoldenrod", rgb: 0xB8860B),
        (name: "darkgray", rgb: 0xA9A9A9),
        (name: "darkgrey", rgb: 0xA9A9A9),
        (name: "darkgreen", rgb: 0x006400),
        (name: "darkkhaki", rgb: 0xBDB76B),
        (name: "darkmagenta", rgb: 0x8B008B),
        (name: "darkolivegreen", rgb: 0x556B2F),
        (name: "darkorange", rgb: 0xFF8C00),
        (name: "darkorchid", rgb: 0x9932CC),
        (name: "darkred", rgb: 0x8B0000),
        (name: "darksalmon", rgb: 0xE9967A),
        (name: "darkseagreen", rgb: 0x8FBC8F),
        (name: "darkslateblue", rgb: 0x483D8B),
        (name: "darkslategray", rgb: 0x2F4F4F),
        (name: "darkslategrey", rgb: 0x2F4F4F),
        (name: "darkturquoise", rgb: 0x00CED1),
        (name: "darkviolet", rgb: 0x9400D3),
        (name: "deeppink", rgb: 0xFF1493),
        (name: "deepskyblue", rgb: 0x00BFFF),
        (name: "dimgray", rgb: 0x696969),
        (name: "dimgrey", rgb: 0x696969),
        (name: "dodgerblue", rgb: 0x1E90FF),
        (name: "firebrick", rgb: 0xB22222),
        (name: "floralwhite", rgb: 0xFFFAF0),
        (name: "forestgreen", rgb: 0x228B22),
        (name: "fuchsia", rgb: 0xFF00FF),
        (name: "gainsboro", rgb: 0xDCDCDC),
        (name: "ghostwhite", rgb: 0xF8F8FF),
        (name: "gold", rgb: 0xFFD700),
        (name: "goldenrod", rgb: 0xDAA520),
        (name: "gray", rgb: 0x808080),
        (name: "grey", rgb: 0x808080),
        (name: "green", rgb: 0x008000),
        (name: "greenyellow", rgb: 0xADFF2F),
        (name: "honeydew", rgb: 0xF0FFF0),
        (name: "hotpink", rgb: 0xFF69B4),
        (name: "indianred", rgb: 0xCD5C5C),
        (name: "indigo", rgb: 0x4B0082),
        (name: "ivory", rgb: 0xFFFFF0),
        (name: "khaki", rgb: 0xF0E68C),
        (name: "lavender", rgb: 0xE6E6FA),
        (name: "lavenderblush", rgb: 0xFFF0F5),
        (name: "lawngreen", rgb: 0x7CFC00),
        (name: "lemonchiffon", rgb: 0xFFFACD),
        (name: "lightblue", rgb: 0xADD8E6),
        (name: "lightcoral", rgb: 0xF08080),
        (name: "lightcyan", rgb: 0xE0FFFF),
        (name: "lightgoldenrodyellow", rgb: 0xFAFAD2),
        (name: "lightgreen", rgb: 0x90EE90),
        (name: "lightgrey", rgb: 0xD3D3D3),
        (name: "lightgray", rgb: 0xD3D3D3),
        (name: "lightpink", rgb: 0xFFB6C1),
        (name: "lightsalmon", rgb: 0xFFA07A),
        (name: "lightseagreen", rgb: 0x20B2AA),
        (name: "lightskyblue", rgb: 0x87CEFA),
        (name: "lightslategray", rgb: 0x778899),
        (name: "lightslategrey", rgb: 0x778899),
        (name: "lightsteelblue", rgb: 0xB0C4DE),
        (name: "lightyellow", rgb: 0xFFFFE0),
        (name: "lime", rgb: 0x00FF00),
        (name: "limegreen", rgb: 0x32CD32),
        (name: "linen", rgb: 0xFAF0E6),
        (name: "magenta", rgb: 0xFF00FF),
        (name: "maroon", rgb: 0x800000),
        (name: "mediumaquamarine", rgb: 0x66CDAA),
        (name: "mediumblue", rgb: 0x0000CD),
        (name: "mediumorchid", rgb: 0xBA55D3),
        (name: "mediumpurple", rgb: 0x9370DB),
        (name: "mediumseagreen", rgb: 0x3CB371),
        (name: "mediumslateblue", rgb: 0x7B68EE),
        (name: "mediumspringgreen", rgb: 0x00FA9A),
        (name: "mediumturquoise", rgb: 0x48D1CC),
        (name: "mediumvioletred", rgb: 0xC71585),
        (name: "midnightblue", rgb: 0x191970),
        (name: "mintcream", rgb: 0xF5FFFA),
        (name: "mistyrose", rgb: 0xFFE4E1),
        (name: "moccasin", rgb: 0xFFE4B5),
        (name: "navajowhite", rgb: 0xFFDEAD),
        (name: "navy", rgb: 0x000080),
        (name: "oldlace", rgb: 0xFDF5E6),
        (name: "olive", rgb: 0x808000),
        (name: "olivedrab", rgb: 0x6B8E23),
        (name: "orange", rgb: 0xFFA500),
        (name: "orangered", rgb: 0xFF4500),
        (name: "orchid", rgb: 0xDA70D6),
        (name: "palegoldenrod", rgb: 0xEEE8AA),
        (name: "palegreen", rgb: 0x98FB98),
        (name: "paleturquoise", rgb: 0xAFEEEE),
        (name: "palevioletred", rgb: 0xDB7093),
        (name: "papayawhip", rgb: 0xFFEFD5),
        (name: "peachpuff", rgb: 0xFFDAB9),
        (name: "peru", rgb: 0xCD853F),
        (name: "pink", rgb: 0xFFC0CB),
        (name: "plum", rgb: 0xDDA0DD),
        (name: "powderblue", rgb: 0xB0E0E6),
        (name: "purple", rgb: 0x800080),
        (name: "rebeccapurple", rgb: 0x663399),
        (name: "red", rgb: 0xFF0000),
        (name: "rosybrown", rgb: 0xBC8F8F),
        (name: "royalblue", rgb: 0x4169E1),
        (name: "saddlebrown", rgb: 0x8B4513),
        (name: "salmon", rgb: 0xFA8072),
        (name: "sandybrown", rgb: 0xF4A460),
        (name: "seagreen", rgb: 0x2E8B57),
        (name: "seashell", rgb: 0xFFF5EE),
        (name: "sienna", rgb: 0xA0522D),
        (name: "silver", rgb: 0xC0C0C0),
        (name: "skyblue", rgb: 0x87CEEB),
        (name: "slateblue", rgb: 0x6A5ACD),
        (name: "slategray", rgb: 0x708090),
        (name: "slategrey", rgb: 0x708090),
        (name: "snow", rgb: 0xFFFAFA),
        (name: "springgreen", rgb: 0x00FF7F),
        (name: "steelblue", rgb: 0x4682B4),
        (name: "tan", rgb: 0xD2B48C),
        (name: "teal", rgb: 0x008080),
        (name: "thistle", rgb: 0xD8BFD8),
        (name: "tomato", rgb: 0xFF6347),
        (name: "turquoise", rgb: 0x40E0D0),
        (name: "violet", rgb: 0xEE82EE),
        (name: "wheat", rgb: 0xF5DEB3),
        (name: "white", rgb: 0xFFFFFF),
        (name: "whitesmoke", rgb: 0xF5F5F5),
        (name: "yellow", rgb: 0xFFFF00),
        (name: "yellowgreen", rgb: 0x9ACD32)
    ]

    /// Lowercased name → source `0xRRGGBB`. Names are unique (only values alias).
    private static let sourceByName: [String: Int] =
        Dictionary(names.map { ($0.name, $0.rgb) }, uniquingKeysWith: { _, new in new })

    /// `ColourNameToRGB(name)` — a named colour or `"#rrggbb"` literal to a
    /// COLORREF (red low byte), or -1 if the name is unknown. Mirrors `SetColour`:
    /// trims, lowercases, parses a leading `#` hex run (R↔B swapped), else looks
    /// up the name table.
    public static func colourNameToRGB(_ name: String) -> Int {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return -1 }
        if trimmed.hasPrefix("#") {
            let hex = trimmed.dropFirst().prefix { $0.isHexDigit }
            guard hex.count <= 6 else { return -1 }
            let parsed = Int(hex, radix: 16) ?? 0 // "#" alone → 0 (black), as SetColour
            return swapRedBlue(parsed)
        }
        guard let source = sourceByName[trimmed] else { return -1 }
        return swapRedBlue(source)
    }

    /// `RGBColourToName(colour)` — a COLORREF to its name, or `"#RRGGBB"` if no
    /// name matches. Mirrors `ColourToName`; on an aliased value we return the
    /// first name in source order (deterministic; see the type doc).
    public static func rgbColourToName(_ colour: Int) -> String {
        let colourref = colour & 0xFFFFFF
        let source = swapRedBlue(colourref)
        if let match = names.first(where: { $0.rgb == source }) {
            return match.name
        }
        let red = colourref & 0xFF
        let green = (colourref >> 8) & 0xFF
        let blue = (colourref >> 16) & 0xFF
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Swap the red and blue bytes of a 24-bit colour. MUSHclient's loader does
    /// this once (source `0xRRGGBB` → COLORREF `0x00BBGGRR`); it is its own
    /// inverse, so the same call converts a COLORREF back for table lookup.
    private static func swapRedBlue(_ value: Int) -> Int {
        let bits = value & 0xFFFFFF
        return ((bits & 0xFF) << 16) | (bits & 0xFF00) | ((bits >> 16) & 0xFF)
    }
}

import MudCore
import SwiftUI

/// Colours + glyphs for the map panel — Proteles' take on the Aardwolf
/// mapper's palette (deep-pink current room, type-coloured tiles), tuned for
/// a dark native window and paired with legible glyphs for special rooms.
enum MapPalette {
    static let background = Color(red: 0.086, green: 0.086, blue: 0.090)
    static let exit = Color(red: 0.56, green: 0.65, blue: 0.71)
    static let exitUpDown = Color(red: 1.0, green: 0.62, blue: 0.77) // pink, like aardmapper
    static let locked = Color(red: 0.79, green: 0.64, blue: 0.15)
    static let note = Color(red: 0.49, green: 0.85, blue: 0.34)
    static let current = Color(red: 1.0, green: 0.18, blue: 0.57) // deep pink

    private static let defaultFill = Color(red: 0.23, green: 0.23, blue: 0.25)
    private static let defaultBorder = Color(red: 0.35, green: 0.35, blue: 0.38)
    private static let otherAreaBorder = Color(red: 0.70, green: 0.25, blue: 0.25)

    /// Resolved drawing attributes for a placed room.
    struct Style {
        let fill: Color
        let border: Color
        let borderWidth: CGFloat
        let glyph: String?
        let glyphColour: Color
    }

    static func style(for room: PlacedRoom) -> Style {
        let (fill, glyph) = fillAndGlyph(for: room.kind)
        var border = defaultBorder
        var width: CGFloat = 1

        switch room.relation {
        case .current:
            border = current
            width = 2.5
        case .otherArea:
            border = otherAreaBorder
        case .sameArea:
            if let tint = room.areaColor.flatMap(parse) { border = tint }
        }
        if room.isPK, room.relation != .current { border = Color(red: 0.85, green: 0.2, blue: 0.2) }

        return Style(
            fill: room.relation == .otherArea ? fill.opacity(0.55) : fill,
            border: border,
            borderWidth: width,
            glyph: glyph,
            glyphColour: .black.opacity(0.82)
        )
    }

    private static func fillAndGlyph(for kind: RoomKind) -> (Color, String?) {
        switch kind {
        case .shop: (Color(red: 1.0, green: 0.68, blue: 0.18), "$")
        case .healer: (Color(red: 0.49, green: 0.85, blue: 0.34), "+")
        case .trainer: (Color(red: 0.49, green: 0.85, blue: 0.34), "T")
        case .guild: (Color(red: 0.83, green: 0.42, blue: 1.0), "G")
        case .questor: (Color(red: 0.21, green: 0.70, blue: 1.0), "Q")
        case .bank: (Color(red: 1.0, green: 0.84, blue: 0.0), "B")
        case .safe: (Color(red: 0.50, green: 0.82, blue: 0.90), "✓")
        case .normal: (defaultFill, nil)
        case .unknown: (defaultFill, nil)
        }
    }

    /// A small tint for the header area dot, derived from the stored colour.
    static func areaTint(_ stored: String?) -> Color {
        stored.flatMap(parse) ?? Color(red: 0.18, green: 0.43, blue: 0.37)
    }

    /// Parse a stored area colour: `#rrggbb` or a few common names. Returns
    /// nil for anything we don't recognise (caller falls back).
    private static func parse(_ string: String) -> Color? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
            return Color(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
        return nil
    }
}

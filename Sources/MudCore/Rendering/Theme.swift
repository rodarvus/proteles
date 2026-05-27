import Foundation

/// A named colour theme: a complete ``ColorPalette`` (16 ANSI colours +
/// foreground/background) plus an `appearance` that tells the app chrome
/// whether to present light or dark. Value-type and `Codable`; the app
/// persists only the selected ``id``.
///
/// Dark themes are primary. The two light themes are hand-tuned and enable the
/// palette's legibility clamp (``ColorPalette/minForegroundContrast``) so MUD
/// text authored for a black background stays readable on a light one.
///
/// - TODO: the light palettes (Solarized Light, Paper) are a serviceable first
///   cut — revisit them; our interpretation of server-side colours on light
///   backgrounds likely wants more tuning than a contrast clamp alone.
public struct Theme: Identifiable, Equatable, Sendable, Codable {
    public enum Appearance: String, Sendable, Codable {
        case dark, light
    }

    public let id: String
    public let name: String
    public let appearance: Appearance
    public let palette: ColorPalette

    public init(id: String, name: String, appearance: Appearance, palette: ColorPalette) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.palette = palette
    }
}

public extension Theme {
    /// Every shipped theme, in display order (Aardwolf first — the default).
    static let all: [Theme] = [aardwolf, protelesDark, solarizedDark, midnightInk, solarizedLight, paper]

    /// The default theme: exact stock-MUSHclient Aardwolf colours.
    static let `default` = aardwolf

    /// Look up a theme by id, falling back to the default.
    static func with(id: String) -> Theme {
        all.first { $0.id == id } ?? .default
    }

    // MARK: - Presets

    /// Stock MUSHclient/Aardwolf VGA palette on black (see the package's
    /// `Aardwolf.mcl` + `SetDefaultAnsiColours`).
    static let aardwolf = Theme(
        id: "aardwolf",
        name: "Aardwolf",
        appearance: .dark,
        palette: palette(
            normal: [0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xC0C0C0],
            bright: [0x808080, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF],
            fg: 0xC0C0C0,
            bg: 0x000000
        )
    )

    /// The previous default: xterm-ish dark.
    static let protelesDark = Theme(
        id: "protelesDark",
        name: "Proteles Dark",
        appearance: .dark,
        palette: .xtermDefault
    )

    static let solarizedDark = Theme(
        id: "solarizedDark",
        name: "Solarized Dark",
        appearance: .dark,
        palette: palette(
            normal: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5],
            bright: [0x586E75, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3],
            fg: 0x839496,
            bg: 0x002B36
        )
    )

    /// A softer, desaturated modern dark.
    static let midnightInk = Theme(
        id: "midnightInk",
        name: "Midnight Ink",
        appearance: .dark,
        palette: palette(
            normal: [0x1A1D27, 0xE0606E, 0x6FCF97, 0xE0C46C, 0x6C9CED, 0xC792EA, 0x56C8D8, 0xC8CCD6],
            bright: [0x5A6072, 0xFF7A85, 0x8EE6AD, 0xFFD97A, 0x8FB6FF, 0xDCB0FF, 0x7FE3F0, 0xFFFFFF],
            fg: 0xC8CCD6,
            bg: 0x11131A
        )
    )

    static let solarizedLight = Theme(
        id: "solarizedLight",
        name: "Solarized Light",
        appearance: .light,
        palette: palette(
            normal: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0x586E75],
            bright: [0x657B83, 0xCB4B16, 0x657B83, 0x586E75, 0x268BD2, 0x6C71C4, 0x2AA198, 0x073642],
            fg: 0x586E75,
            bg: 0xFDF6E3,
            clamp: 3.0
        )
    )

    /// Warm light: the normally-light slots map to dark ink so "white" text
    /// stays legible; accents are darkened.
    static let paper = Theme(
        id: "paper",
        name: "Paper",
        appearance: .light,
        palette: palette(
            normal: [0x5B5750, 0xB0202A, 0x2E7D32, 0x9A7D00, 0x1565C0, 0x8E24AA, 0x00838F, 0x33312B],
            bright: [0x8A857B, 0xD0323C, 0x2E9E3A, 0xB8920A, 0x1976D2, 0xA13BC0, 0x0097A7, 0x1A1814],
            fg: 0x33312B,
            bg: 0xF5EFE0,
            clamp: 3.0
        )
    )

    // MARK: - Builders

    private static let ansiOrder: [NamedColor] = [
        .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white
    ]

    private static func palette(
        normal: [UInt32], bright: [UInt32], fg: UInt32, bg: UInt32, clamp: Double? = nil
    ) -> ColorPalette {
        var named: [NamedColor: RGB] = [:]
        var brightNamed: [NamedColor: RGB] = [:]
        for (index, name) in ansiOrder.enumerated() {
            named[name] = rgb(normal[index])
            brightNamed[name] = rgb(bright[index])
        }
        return ColorPalette(
            named: named,
            brightNamed: brightNamed,
            defaultForeground: rgb(fg),
            defaultBackground: rgb(bg),
            minForegroundContrast: clamp
        )
    }

    private static func rgb(_ hex: UInt32) -> RGB {
        RGB(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }
}

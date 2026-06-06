import Foundation

/// A named colour theme: a complete ``ColorPalette`` (16 ANSI colours +
/// foreground/background) plus an `appearance` that tells the app chrome
/// whether to present light or dark. Value-type and `Codable`; the app
/// persists only the selected ``id``.
///
/// Dark themes are primary. The one light theme (Catppuccin Latte) enables the
/// palette's legibility clamp (``ColorPalette/minForegroundContrast``) so MUD
/// text authored for a black background stays readable on a light one.
///
/// Most presets are community colour schemes from the iTerm2-Color-Schemes
/// gallery (<https://github.com/mbadolato/iTerm2-Color-Schemes>); each preset
/// below is attributed to its scheme author. The canonical palettes are
/// reproduced (16 ANSI colours + foreground/background).
///
/// - TODO: Catppuccin Latte is the only light theme for now; our interpretation
///   of server-side colours on light backgrounds may want more tuning than the
///   contrast clamp alone.
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
    static let all: [Theme] = [
        aardwolf, midnightInk,
        dracula, nord, tokyoNight, catppuccinMocha, gruvboxDark, oneDark, snazzy,
        catppuccinLatte
    ]

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

    /// A soft, desaturated modern dark (a Proteles original).
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

    // MARK: - iTerm2 community schemes (iTerm2-Color-Schemes gallery)

    /// Dracula — by Zeno Rocha (draculatheme.com).
    static let dracula = Theme(
        id: "dracula",
        name: "Dracula",
        appearance: .dark,
        palette: palette(
            normal: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2],
            bright: [0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF],
            fg: 0xF8F8F2,
            bg: 0x282A36
        )
    )

    /// Nord — by Arctic Ice Studio (nordtheme.com).
    static let nord = Theme(
        id: "nord",
        name: "Nord",
        appearance: .dark,
        palette: palette(
            normal: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0],
            bright: [0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4],
            fg: 0xD8DEE9,
            bg: 0x2E3440
        )
    )

    /// Tokyo Night — by enkia.
    static let tokyoNight = Theme(
        id: "tokyoNight",
        name: "Tokyo Night",
        appearance: .dark,
        palette: palette(
            normal: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6],
            bright: [0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5],
            fg: 0xC0CAF5,
            bg: 0x1A1B26
        )
    )

    /// Catppuccin Mocha — by the Catppuccin project.
    static let catppuccinMocha = Theme(
        id: "catppuccinMocha",
        name: "Catppuccin Mocha",
        appearance: .dark,
        palette: palette(
            normal: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE],
            bright: [0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8],
            fg: 0xCDD6F4,
            bg: 0x1E1E2E
        )
    )

    /// Gruvbox Dark — by Pavel Pertsev (morhetz).
    static let gruvboxDark = Theme(
        id: "gruvboxDark",
        name: "Gruvbox Dark",
        appearance: .dark,
        palette: palette(
            normal: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984],
            bright: [0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2],
            fg: 0xEBDBB2,
            bg: 0x282828
        )
    )

    /// One Dark — Atom's editor theme.
    static let oneDark = Theme(
        id: "oneDark",
        name: "One Dark",
        appearance: .dark,
        palette: palette(
            normal: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF],
            bright: [0x545862, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xC8CCD4],
            fg: 0xABB2BF,
            bg: 0x282C34
        )
    )

    /// Snazzy — by Sindre Sorhus (hyper-snazzy).
    static let snazzy = Theme(
        id: "snazzy",
        name: "Snazzy",
        appearance: .dark,
        palette: palette(
            normal: [0x282A36, 0xFF5C57, 0x5AF78E, 0xF3F99D, 0x57C7FF, 0xFF6AC1, 0x9AEDFE, 0xF1F1F0],
            bright: [0x686868, 0xFF5C57, 0x5AF78E, 0xF3F99D, 0x57C7FF, 0xFF6AC1, 0x9AEDFE, 0xEFF0EB],
            fg: 0xEFF0EB,
            bg: 0x282A36
        )
    )

    /// Catppuccin Latte (light) — by the Catppuccin project. The light slots are
    /// pale, so the contrast clamp keeps MUD bright-white legible on the warm bg.
    static let catppuccinLatte = Theme(
        id: "catppuccinLatte",
        name: "Catppuccin Latte",
        appearance: .light,
        palette: palette(
            normal: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE],
            bright: [0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC],
            fg: 0x4C4F69,
            bg: 0xEFF1F5,
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
            minForegroundContrast: clamp,
            // Dark themes (no light-bg clamp) get Aardwolf's dark-xterm remap so
            // near-black / dark-navy codes stay readable on a dark background;
            // light themes use the contrast clamp instead.
            remapsDarkXterm: clamp == nil
        )
    }

    private static func rgb(_ hex: UInt32) -> RGB {
        RGB(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }
}

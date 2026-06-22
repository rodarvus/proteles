@testable import MudCore
import Testing

@Suite("Theme presets")
struct ThemeTests {
    @Test("The default is Aardwolf and every preset has a unique id")
    func defaultAndIDs() {
        #expect(Theme.default.id == "aardwolf")
        let ids = Theme.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count, "ids must be unique")
        #expect(Theme.with(id: "nope").id == "aardwolf", "unknown id falls back to default")
    }

    @Test("Every preset defines all 8 normal + 8 bright ANSI colours")
    func completePalettes() {
        for theme in Theme.builtIns {
            #expect(theme.palette.named.count == 8, "\(theme.id) normal")
            #expect(theme.palette.brightNamed.count == 8, "\(theme.id) bright")
        }
    }

    @Test("Aardwolf matches the stock MUSHclient VGA palette")
    func aardwolfValues() {
        let palette = Theme.aardwolf.palette
        #expect(palette.named[.red] == RGB(0x80, 0, 0), "maroon")
        #expect(palette.brightNamed[.white] == RGB(0xFF, 0xFF, 0xFF))
        #expect(palette.defaultBackground == RGB(0, 0, 0))
        #expect(palette.defaultForeground == RGB(0xC0, 0xC0, 0xC0), "silver")
    }

    @Test("Only light themes enable the legibility clamp")
    func clampOnLightOnly() {
        for theme in Theme.builtIns {
            if theme.appearance == .light {
                #expect(theme.palette.minForegroundContrast != nil, "\(theme.id) should clamp")
            } else {
                #expect(theme.palette.minForegroundContrast == nil, "\(theme.id) shouldn't clamp")
            }
        }
    }

    @Test("User theme collections ignore reserved ids and incomplete palettes")
    func userThemeSanitizing() {
        var valid = Theme.aardwolf
        valid.id = "user.ok"
        valid.name = "Custom"
        var reserved = valid
        reserved.id = Theme.aardwolf.id
        var incomplete = valid
        incomplete.id = "user.bad"
        incomplete.palette.named[.red] = nil

        let sanitized = UserThemeCollection(themes: [reserved, incomplete, valid, valid]).sanitized()
        #expect(sanitized.themes.map(\.id) == ["user.ok"])
    }
}

@Suite("ColorPalette — light-theme legibility clamp")
struct ColorPaletteClampTests {
    /// A light palette: cream background, dark ink, clamp at 3:1.
    private let light = ColorPalette(
        named: [.white: RGB(0xF0, 0xF0, 0xF0)],
        brightNamed: [.white: RGB(0xFF, 0xFF, 0xFF)],
        defaultForeground: RGB(0x33, 0x31, 0x2B),
        defaultBackground: RGB(0xF5, 0xEF, 0xE0),
        minForegroundContrast: 3.0
    )

    @Test("Near-white foreground on a light background clamps to the ink")
    func clampsLowContrast() {
        // Bright white has almost no contrast with the cream bg → ink.
        #expect(light.resolveForeground(.brightNamed(.white)) == RGB(0x33, 0x31, 0x2B))
    }

    @Test("A dark, high-contrast colour passes through unclamped")
    func keepsHighContrast() {
        let navy = ANSIColor.rgb(red: 0x15, green: 0x65, blue: 0xC0)
        #expect(light.resolveForeground(navy) == RGB(0x15, 0x65, 0xC0))
    }

    @Test("Without a clamp, colours pass through verbatim (dark themes)")
    func noClampPassthrough() {
        let dark = ColorPalette.xtermDefault
        #expect(dark.resolveForeground(.brightNamed(.white)) == RGB(0xFF, 0xFF, 0xFF))
    }
}

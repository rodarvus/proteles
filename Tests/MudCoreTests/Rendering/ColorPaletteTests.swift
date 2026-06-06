@testable import MudCore
import Testing

@Suite("ColorPalette — named colours")
struct ColorPalettePresetTests {
    @Test("xtermDefault contains all eight named foreground colours")
    func xtermDefaultIsComplete() {
        let palette = ColorPalette.xtermDefault
        for color in NamedColor.allCases {
            #expect(palette.named[color] != nil, "missing named \(color)")
            #expect(palette.brightNamed[color] != nil, "missing brightNamed \(color)")
        }
    }

    @Test("Resolve(.named) returns the configured palette entry")
    func resolveNamed() {
        let palette = ColorPalette.xtermDefault
        #expect(palette.resolve(.named(.red)) == RGB(205, 0, 0))
        #expect(palette.resolve(.named(.black)) == RGB(0, 0, 0))
        #expect(palette.resolve(.named(.white)) == RGB(229, 229, 229))
    }

    @Test("Resolve(.brightNamed) returns the bright palette entry")
    func resolveBrightNamed() {
        let palette = ColorPalette.xtermDefault
        #expect(palette.resolve(.brightNamed(.red)) == RGB(255, 0, 0))
        #expect(palette.resolve(.brightNamed(.black)) == RGB(127, 127, 127))
    }

    @Test("Resolve(.rgb) passes through unchanged")
    func resolveRGBPassesThrough() {
        let palette = ColorPalette.xtermDefault
        #expect(
            palette.resolve(.rgb(red: 17, green: 34, blue: 51))
                == RGB(17, 34, 51)
        )
    }
}

@Suite("ColorPalette — 8-bit palette (xterm-256)")
struct ColorPalettePaletteIndexTests {
    @Test("Indices 0–7 alias the named foreground colours")
    func indices0to7AliasNamed() throws {
        let palette = ColorPalette.xtermDefault
        for offset in 0..<8 {
            let named = try #require(NamedColor(rawValue: UInt8(offset)))
            #expect(
                palette.resolve(.palette(UInt8(offset)))
                    == palette.resolve(.named(named)),
                "index \(offset) should match named \(named)"
            )
        }
    }

    @Test("Indices 8–15 alias the bright named colours")
    func indices8to15AliasBrightNamed() throws {
        let palette = ColorPalette.xtermDefault
        for offset in 0..<8 {
            let named = try #require(NamedColor(rawValue: UInt8(offset)))
            #expect(
                palette.resolve(.palette(UInt8(8 + offset)))
                    == palette.resolve(.brightNamed(named)),
                "index \(8 + offset) should match brightNamed \(named)"
            )
        }
    }

    @Test("Index 16 is the cube origin (0,0,0)")
    func index16IsCubeOrigin() {
        #expect(ColorPalette.xtermDefault.resolve(.palette(16)) == RGB(0, 0, 0))
    }

    @Test("Index 196 is the canonical xterm red cube cell")
    func index196IsCubeRed() {
        #expect(
            ColorPalette.xtermDefault.resolve(.palette(196)) == RGB(255, 0, 0)
        )
    }

    @Test("Index 21 is cube (0,0,5) = blue corner")
    func index21IsCubeBlue() {
        #expect(
            ColorPalette.xtermDefault.resolve(.palette(21)) == RGB(0, 0, 255)
        )
    }

    @Test("Index 231 is the cube corner (255,255,255)")
    func index231IsCubeWhite() {
        #expect(
            ColorPalette.xtermDefault.resolve(.palette(231))
                == RGB(255, 255, 255)
        )
    }

    @Test("Index 232 is the first gray (8,8,8)")
    func index232IsFirstGray() {
        #expect(
            ColorPalette.xtermDefault.resolve(.palette(232)) == RGB(8, 8, 8)
        )
    }

    @Test("Index 255 is the last gray (238,238,238)")
    func index255IsLastGray() {
        #expect(
            ColorPalette.xtermDefault.resolve(.palette(255))
                == RGB(238, 238, 238)
        )
    }
}

@Suite("ColorPalette — defaults")
struct ColorPaletteDefaultsTests {
    @Test("resolveForeground(nil) returns defaultForeground")
    func resolveForegroundNilFallsBack() {
        let palette = ColorPalette.xtermDefault
        #expect(palette.resolveForeground(nil) == palette.defaultForeground)
    }

    @Test("resolveBackground(nil) returns defaultBackground")
    func resolveBackgroundNilFallsBack() {
        let palette = ColorPalette.xtermDefault
        #expect(palette.resolveBackground(nil) == palette.defaultBackground)
    }
}

@Suite("ColorPalette — dark-xterm remap (Aardwolf x_not_too_dark)")
struct ColorPaletteDarkRemapTests {
    /// The dark default theme bumps the very-darkest xterm indices to the
    /// reference's readable substitutes (`aardwolf_colors.lua`).
    @Test("Dark theme remaps near-black / dark-navy / darkest-gray indices")
    func darkThemeRemapsDarkIndices() {
        let palette = Theme.aardwolf.palette
        // 0 and 16 → 7 (silver / named white).
        #expect(palette.resolve(.palette(0)) == palette.resolve(.palette(7)))
        #expect(palette.resolve(.palette(16)) == palette.resolve(.palette(7)))
        // 17 and 18 → 19 (dark navy → readable blue).
        #expect(palette.resolve(.palette(17)) == palette.resolve(.palette(19)))
        #expect(palette.resolve(.palette(18)) == palette.resolve(.palette(19)))
        // 232…237 → 238 (darkest grays → a readable gray).
        for index in 232...237 {
            #expect(palette.resolve(.palette(UInt8(index))) == palette.resolve(.palette(238)))
        }
    }

    @Test("Dark remap leaves ordinary cube + bright indices untouched")
    func darkRemapLeavesOthersAlone() {
        let palette = Theme.aardwolf.palette
        #expect(palette.resolve(.palette(196)) == RGB(255, 0, 0)) // cube red
        #expect(palette.resolve(.palette(19)) == RGB(0, 0, 175)) // the target itself
        #expect(palette.resolve(.palette(238)) == RGB(68, 68, 68)) // target gray
    }

    /// Light themes use the contrast clamp, not the dark remap — black must stay
    /// black (remapping it to silver would be wrong on a light background).
    @Test("Light theme does not apply the dark remap")
    func lightThemeSkipsRemap() {
        let palette = Theme.catppuccinLatte.palette
        #expect(!palette.remapsDarkXterm)
        // Index 16 is the cube origin (0,0,0) — unchanged on a light theme.
        #expect(palette.resolve(.palette(16)) == RGB(0, 0, 0))
    }

    @Test("remappedDarkIndex matches the reference table verbatim")
    func helperMatchesReference() {
        #expect(ColorPalette.remappedDarkIndex(0) == 7)
        #expect(ColorPalette.remappedDarkIndex(16) == 7)
        #expect(ColorPalette.remappedDarkIndex(17) == 19)
        #expect(ColorPalette.remappedDarkIndex(18) == 19)
        #expect(ColorPalette.remappedDarkIndex(235) == 238)
        #expect(ColorPalette.remappedDarkIndex(100) == 100) // identity elsewhere
    }
}

@Suite("ColorPalette — bold = bright (MUSHclient <bold> ANSI table)")
struct ColorPaletteBoldBrightTests {
    private let palette = Theme.aardwolf.palette

    @Test("Bold upgrades the 8 basic named colours to their bright variants")
    func boldUpgradesNamed() {
        // Bold-black must NOT be (0,0,0) (invisible on black) — it's bright gray.
        #expect(palette.resolveForeground(.named(.black), bold: true) == RGB(128, 128, 128))
        // Bold-blue is bright blue (0,0,255), not dark navy (0,0,128).
        #expect(palette.resolveForeground(.named(.blue), bold: true) == RGB(0, 0, 255))
        #expect(palette.resolveForeground(.named(.cyan), bold: true) == RGB(0, 255, 255))
        // Each bold named == the corresponding brightNamed entry.
        for color in NamedColor.allCases {
            #expect(
                palette.resolveForeground(.named(color), bold: true)
                    == palette.resolve(.brightNamed(color)),
                "bold .named(\(color)) should equal .brightNamed(\(color))"
            )
        }
    }

    @Test("Non-bold named colours stay normal (dark)")
    func nonBoldStaysNormal() {
        #expect(palette.resolveForeground(.named(.black), bold: false) == RGB(0, 0, 0))
        #expect(palette.resolveForeground(.named(.blue), bold: false) == RGB(0, 0, 128))
        // The no-bold overload matches bold:false.
        #expect(palette.resolveForeground(.named(.blue)) == RGB(0, 0, 128))
    }

    @Test("Bold does not alter xterm-256, 24-bit, or already-bright colours")
    func boldLeavesExplicitColoursAlone() {
        #expect(palette.resolveForeground(.palette(196), bold: true) == RGB(255, 0, 0))
        #expect(
            palette.resolveForeground(.rgb(red: 10, green: 20, blue: 30), bold: true)
                == RGB(10, 20, 30)
        )
        #expect(
            palette.resolveForeground(.brightNamed(.blue), bold: true)
                == palette.resolve(.brightNamed(.blue))
        )
    }
}

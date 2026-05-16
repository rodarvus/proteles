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

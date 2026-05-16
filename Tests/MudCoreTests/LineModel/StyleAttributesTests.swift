@testable import MudCore
import Testing

@Suite("StyleAttributes")
struct StyleAttributesTests {
    @Test("default equals default-initialised value")
    func defaultIsEqual() {
        #expect(StyleAttributes.default == StyleAttributes())
        #expect(StyleAttributes().isDefault)
    }

    @Test("Equality is by field")
    func equalityIsByFields() {
        var lhs = StyleAttributes()
        let rhs = StyleAttributes()
        #expect(lhs == rhs)

        lhs.bold = true
        #expect(lhs != rhs)
    }

    @Test("Hashable distinguishes styles")
    func hashableDistinguishesStyles() {
        let bold = StyleAttributes(bold: true)
        let italic = StyleAttributes(italic: true)
        var set: Set<StyleAttributes> = [bold]
        set.insert(italic)
        set.insert(StyleAttributes(bold: true))
        #expect(set.count == 2)
    }

    @Test("Foreground / background carry independent colour info")
    func independentForegroundAndBackground() {
        let style = StyleAttributes(
            foreground: .named(.red),
            background: .palette(238)
        )
        #expect(style.foreground == .named(.red))
        #expect(style.background == .palette(238))
    }
}

@Suite("ANSIColor")
struct ANSIColorTests {
    @Test("Named colour raw values match SGR offsets")
    func namedColorRawValues() {
        #expect(NamedColor.black.rawValue == 0)
        #expect(NamedColor.red.rawValue == 1)
        #expect(NamedColor.white.rawValue == 7)
    }

    @Test("Equality across variants")
    func equalityAcrossVariants() {
        let red1: ANSIColor = .named(.red)
        let red2: ANSIColor = .named(.red)
        let palette1: ANSIColor = .palette(196)
        let palette2: ANSIColor = .palette(196)
        let rgb1: ANSIColor = .rgb(red: 255, green: 0, blue: 0)
        let rgb2: ANSIColor = .rgb(red: 255, green: 0, blue: 0)

        #expect(red1 == red2)
        #expect(red1 != .brightNamed(.red))
        #expect(palette1 == palette2)
        #expect(palette1 != .palette(197))
        #expect(rgb1 == rgb2)
        #expect(rgb1 != .rgb(red: 254, green: 0, blue: 0))
    }

    @Test("All eight named colours have unique raw values")
    func allNamedColorsUnique() {
        #expect(Set(NamedColor.allCases.map(\.rawValue)).count == 8)
    }
}

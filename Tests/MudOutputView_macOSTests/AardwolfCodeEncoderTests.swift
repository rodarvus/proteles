#if os(macOS)
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    @Suite("AardwolfCodeEncoder — encoding a Line")
    struct AardwolfCodeEncoderLineTests {
        private let encoder = AardwolfCodeEncoder()

        private func line(_ text: String, _ runs: [StyledRun]) -> Line {
            Line(id: LineID(0), text: text, runs: runs)
        }

        @Test("Plain line emits no codes (leading @w suppressed)")
        func plainLine() {
            #expect(encoder.encode(line("hello", [])) == "hello")
        }

        @Test("A named-colour run gets @r; default tail resets to @w")
        func namedRunThenDefault() {
            let red = StyleAttributes(foreground: .named(.red))
            // "redOK": 0..<3 red, 3..<5 default → @r red @w OK.
            let result = encoder.encode(line("redOK", [StyledRun(utf16Range: 0..<3, style: red)]))
            #expect(result == "@rred@wOK")
        }

        @Test("Bold named colour → bright (uppercase) code")
        func boldNamedIsBright() {
            let boldRed = StyleAttributes(foreground: .named(.red), bold: true)
            #expect(encoder.encode(line("hi", [StyledRun(utf16Range: 0..<2, style: boldRed)])) == "@Rhi")
        }

        @Test("brightNamed → uppercase code")
        func brightNamed() {
            let brightCyan = StyleAttributes(foreground: .brightNamed(.cyan))
            #expect(encoder.encode(line("x", [StyledRun(utf16Range: 0..<1, style: brightCyan)])) == "@Cx")
        }

        @Test("palette index → @xNNN (zero-padded)")
        func paletteToXterm() {
            let pal = StyleAttributes(foreground: .palette(123))
            #expect(encoder.encode(line("p", [StyledRun(utf16Range: 0..<1, style: pal)])) == "@x123p")
            let pal9 = StyleAttributes(foreground: .palette(9))
            #expect(encoder.encode(line("q", [StyledRun(utf16Range: 0..<1, style: pal9)])) == "@x009q")
        }

        @Test("Exact-16 RGB → named code; off-palette RGB → nearest @xNNN")
        func rgbMapping() {
            // 0xAA0000 is normal red in our table → @r.
            let exactRed = StyleAttributes(foreground: .rgb(red: 0xAA, green: 0, blue: 0))
            #expect(encoder.encode(line("z", [StyledRun(utf16Range: 0..<1, style: exactRed)])) == "@rz")
            // (95,0,0) is the 6×6×6 cube cell (1,0,0) = index 16+36 = 52, exact.
            let cube = StyleAttributes(foreground: .rgb(red: 95, green: 0, blue: 0))
            #expect(encoder.encode(line("c", [StyledRun(utf16Range: 0..<1, style: cube)])) == "@x052c")
        }

        @Test("Literal @ in text is doubled to @@")
        func escapesAtSign() {
            #expect(encoder.encode(line("a@b", [])) == "a@@b")
        }
    }
#endif

#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    @Suite("AttributedStringBuilder — plain")
    @MainActor
    struct AttributedStringBuilderPlainTests {
        @Test("Plain line renders with default font and foreground")
        func plainLine() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            )
            let line = Line(id: LineID(0), text: "hello", runs: [])
            let attributed = builder.build(line)

            #expect(attributed.string == "hello\n")

            var range = NSRange(location: 0, length: 0)
            let attributes = attributed.attributes(
                at: 0,
                effectiveRange: &range
            )
            let foreground = attributes[.foregroundColor] as? NSColor
            #expect(
                foreground == NSColor(ColorPalette.xtermDefault.defaultForeground)
            )
            let font = attributes[.font] as? NSFont
            #expect(font?.pointSize == 13)
        }

        @Test("Line ends with a newline so consecutive appends form lines")
        func endsWithNewline() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            )
            let line = Line(id: LineID(0), text: "abc", runs: [])
            let attributed = builder.build(line)
            #expect(attributed.string.last == "\n")
        }
    }

    @Suite("AttributedStringBuilder — styled runs")
    @MainActor
    struct AttributedStringBuilderStyledRunsTests {
        private let baseFont = NSFont.monospacedSystemFont(
            ofSize: 13,
            weight: .regular
        )

        @Test("A single bold run sets a bold font on the run range")
        func boldFontApplied() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: baseFont
            )
            let run = StyledRun(
                utf16Range: 0..<3,
                style: StyleAttributes(bold: true)
            )
            let line = Line(id: LineID(0), text: "ABC", runs: [run])
            let attributed = builder.build(line)

            var range = NSRange(location: 0, length: 0)
            let attributes = attributed.attributes(
                at: 0,
                effectiveRange: &range
            )
            let font = attributes[.font] as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }

        @Test("Foreground colour is resolved through the palette")
        func foregroundColorResolved() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: baseFont
            )
            let run = StyledRun(
                utf16Range: 0..<3,
                style: StyleAttributes(foreground: .named(.red))
            )
            let line = Line(id: LineID(0), text: "RED", runs: [run])
            let attributed = builder.build(line)

            var range = NSRange(location: 0, length: 0)
            let attributes = attributed.attributes(
                at: 0,
                effectiveRange: &range
            )
            let foreground = attributes[.foregroundColor] as? NSColor
            #expect(foreground == NSColor(RGB(205, 0, 0)))
        }

        @Test("Reverse video swaps resolved fg and bg")
        func reverseVideoSwapsForegroundAndBackground() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: baseFont
            )
            let style = StyleAttributes(
                foreground: .named(.red),
                background: .named(.blue),
                reverse: true
            )
            let run = StyledRun(utf16Range: 0..<2, style: style)
            let line = Line(id: LineID(0), text: "XY", runs: [run])
            let attributed = builder.build(line)

            var range = NSRange(location: 0, length: 0)
            let attributes = attributed.attributes(
                at: 0,
                effectiveRange: &range
            )
            #expect(
                attributes[.foregroundColor] as? NSColor == NSColor(RGB(0, 0, 238))
            )
            #expect(
                attributes[.backgroundColor] as? NSColor == NSColor(RGB(205, 0, 0))
            )
        }

        @Test("Underline attribute is applied when style.underline is set")
        func underlineApplied() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: baseFont
            )
            let run = StyledRun(
                utf16Range: 0..<3,
                style: StyleAttributes(underline: true)
            )
            let line = Line(id: LineID(0), text: "ABC", runs: [run])
            let attributed = builder.build(line)

            var range = NSRange(location: 0, length: 0)
            let attributes = attributed.attributes(
                at: 0,
                effectiveRange: &range
            )
            let style = attributes[.underlineStyle] as? Int
            #expect(style == NSUnderlineStyle.single.rawValue)
        }

        @Test("Style boundaries follow run boundaries in the output")
        func runBoundariesAreRespected() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: baseFont
            )
            let run = StyledRun(
                utf16Range: 2..<4,
                style: StyleAttributes(foreground: .named(.green))
            )
            let line = Line(id: LineID(0), text: "abcdef", runs: [run])
            let attributed = builder.build(line)

            var range = NSRange(location: 0, length: 0)
            let attributesAt0 = attributed.attributes(
                at: 0,
                effectiveRange: &range
            )
            let attributesAt2 = attributed.attributes(
                at: 2,
                effectiveRange: &range
            )
            let foreground0 = attributesAt0[.foregroundColor] as? NSColor
            let foreground2 = attributesAt2[.foregroundColor] as? NSColor
            #expect(foreground0 == NSColor(RGB(229, 229, 229)))
            #expect(foreground2 == NSColor(RGB(0, 205, 0)))
        }
    }
#endif

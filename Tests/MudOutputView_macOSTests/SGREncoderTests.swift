#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    @Suite("SGREncoder — encoding a Line")
    struct SGREncoderLineTests {
        @Test("Plain line emits no SGR codes")
        func plainLine() {
            let encoder = SGREncoder()
            let line = Line(id: LineID(0), text: "hello", runs: [])
            #expect(encoder.encode(line) == "hello")
        }

        @Test("Single styled run gets a leading SGR and a trailing reset")
        func singleStyledRun() {
            let encoder = SGREncoder()
            let red = StyleAttributes(foreground: .named(.red))
            let line = Line(
                id: LineID(0),
                text: "warn",
                runs: [StyledRun(utf16Range: 0..<4, style: red)]
            )
            #expect(encoder.encode(line) == "\u{1B}[0;31mwarn\u{1B}[0m")
        }

        @Test("Default-styled prefix is uncoded; styled middle bracketed by SGR/reset")
        func styledMiddle() {
            let encoder = SGREncoder()
            let bold = StyleAttributes(bold: true)
            let line = Line(
                id: LineID(0),
                text: "plain bold plain",
                runs: [StyledRun(utf16Range: 6..<10, style: bold)]
            )
            #expect(
                encoder.encode(line) == "plain \u{1B}[0;1mbold\u{1B}[0m plain"
            )
        }

        @Test("Bright + 24-bit RGB foregrounds use SGR 9X and 38;2;R;G;B")
        func brightAndRGBForegrounds() {
            let encoder = SGREncoder()
            let bright = StyleAttributes(foreground: .brightNamed(.cyan))
            let rgb = StyleAttributes(
                foreground: .rgb(red: 255, green: 128, blue: 0)
            )
            let line = Line(
                id: LineID(0),
                text: "AB",
                runs: [
                    StyledRun(utf16Range: 0..<1, style: bright),
                    StyledRun(utf16Range: 1..<2, style: rgb)
                ]
            )
            // Adjacent runs with different styles: reset+apply between each.
            let expected =
                "\u{1B}[0;96mA"
                    + "\u{1B}[0;38;2;255;128;0mB"
                    + "\u{1B}[0m"
            #expect(encoder.encode(line) == expected)
        }

        @Test("Combined attributes encode in canonical SGR order")
        func combinedAttributes() {
            let encoder = SGREncoder()
            let style = StyleAttributes(
                foreground: .named(.green),
                background: .named(.black),
                bold: true,
                underline: true
            )
            let line = Line(
                id: LineID(0),
                text: "ok",
                runs: [StyledRun(utf16Range: 0..<2, style: style)]
            )
            #expect(
                encoder.encode(line) == "\u{1B}[0;1;4;32;40mok\u{1B}[0m"
            )
        }
    }

    @Suite("SGREncoder — encoding an NSAttributedString")
    @MainActor
    struct SGREncoderAttributedStringTests {
        private let baseFont = NSFont.monospacedSystemFont(
            ofSize: 13,
            weight: .regular
        )

        @Test("Builder-produced attributed string round-trips via the encoder")
        func builderRoundTrip() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: baseFont
            )
            let red = StyleAttributes(foreground: .named(.red))
            let line = Line(
                id: LineID(0),
                text: "danger",
                runs: [StyledRun(utf16Range: 0..<6, style: red)]
            )
            let attributed = builder.build(line)

            // Drop the trailing newline that AttributedStringBuilder adds —
            // copying from a selection wouldn't include it.
            let trimmedRange = NSRange(location: 0, length: attributed.length - 1)
            let trimmed = attributed.attributedSubstring(from: trimmedRange)

            let encoder = SGREncoder()
            #expect(encoder.encode(trimmed) == "\u{1B}[0;31mdanger\u{1B}[0m")
        }

        @Test("Attributed string with no protelesStyle decodes as plain text")
        func unmarkedTextIsPlain() {
            let attributed = NSAttributedString(string: "hello, world")
            let encoder = SGREncoder()
            #expect(encoder.encode(attributed) == "hello, world")
        }

        @Test("Multi-line selection preserves the line-feed character")
        func multilineSelection() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: baseFont
            )
            let red = StyleAttributes(foreground: .named(.red))
            let firstLine = Line(
                id: LineID(0),
                text: "first",
                runs: [StyledRun(utf16Range: 0..<5, style: red)]
            )
            let secondLine = Line(
                id: LineID(1),
                text: "second",
                runs: []
            )
            let combined = NSMutableAttributedString()
            combined.append(builder.build(firstLine))
            combined.append(builder.build(secondLine))

            let encoder = SGREncoder()
            let encoded = encoder.encode(combined)
            // The newline between lines (from AttributedStringBuilder) is
            // outside the styled run, so the encoder resets before it.
            #expect(encoded.contains("\u{1B}[0;31mfirst\u{1B}[0m"))
            #expect(encoded.contains("\nsecond\n"))
        }
    }

    @Suite("SGREncoder + ANSIParser — round-trip")
    struct SGREncoderRoundTripTests {
        @Test("Encode then re-parse yields a Line with the same text and runs")
        func encodeThenParseRoundTrip() {
            let encoder = SGREncoder()
            let bold = StyleAttributes(bold: true)
            let red = StyleAttributes(foreground: .named(.red))
            let original = Line(
                id: LineID(0),
                text: "alpha beta gamma",
                runs: [
                    StyledRun(utf16Range: 6..<10, style: bold),
                    StyledRun(utf16Range: 11..<16, style: red)
                ]
            )
            let encoded = encoder.encode(original) + "\n"

            var parser = ANSIParser()
            var builder = LineBuilder()
            var parsedLines: [Line] = []
            parser.process(Array(encoded.utf8)) { event in
                builder.consume(event) { line in parsedLines.append(line) }
            }
            parser.flush { event in
                builder.consume(event) { line in parsedLines.append(line) }
            }
            builder.flush { line in parsedLines.append(line) }

            #expect(parsedLines.count == 1)
            #expect(parsedLines[0].text == original.text)
            #expect(parsedLines[0].runs == original.runs)
        }
    }
#endif

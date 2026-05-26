#if os(macOS)
    import Foundation
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    @Suite("HTMLEncoder — encoding a Line")
    struct HTMLEncoderLineTests {
        private let encoder = HTMLEncoder()

        private func line(_ text: String, _ runs: [StyledRun]) -> Line {
            Line(id: LineID(0), text: text, runs: runs)
        }

        /// The on-screen hex for an ANSIColor via the default palette (so the
        /// tests track the palette rather than hardcoding values).
        private func hex(_ color: ANSIColor) -> String {
            let rgb = ColorPalette.xtermDefault.resolveForeground(color)
            return String(format: "%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
        }

        @Test("Empty selection encodes to nothing")
        func empty() {
            #expect(encoder.encode(line("", [])).isEmpty)
        }

        @Test("Plain line is wrapped in <pre> with no spans")
        func plainLine() {
            #expect(encoder.encode(line("hello", [])) == "<pre>hello</pre>")
        }

        @Test("A coloured run becomes a styled span; default tail is plain")
        func colouredRunThenDefault() {
            let red = StyleAttributes(foreground: .named(.red))
            let result = encoder.encode(line("redOK", [StyledRun(utf16Range: 0..<3, style: red)]))
            #expect(result == "<pre><span style=\"color:#\(hex(.named(.red)))\">red</span>OK</pre>")
        }

        @Test("Bold adds font-weight; underline adds text-decoration")
        func boldUnderline() {
            let style = StyleAttributes(foreground: .named(.cyan), bold: true, underline: true)
            let result = encoder.encode(line("x", [StyledRun(utf16Range: 0..<1, style: style)]))
            let expected = "<pre><span style=\"color:#\(hex(.named(.cyan)));"
                + "font-weight:bold;text-decoration:underline\">x</span></pre>"
            #expect(result == expected)
        }

        @Test("Bold with no colour still produces a span (font-weight only)")
        func boldNoColour() {
            let style = StyleAttributes(bold: true)
            #expect(encoder.encode(line("b", [StyledRun(utf16Range: 0..<1, style: style)]))
                == "<pre><span style=\"font-weight:bold\">b</span></pre>")
        }

        @Test("HTML metacharacters are escaped (&, <, >)")
        func escaping() {
            #expect(encoder.encode(line("a & b < c > d", [])) == "<pre>a &amp; b &lt; c &gt; d</pre>")
        }
    }
#endif

#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudOutputView_macOS
    import Testing

    @Suite("AttributedStringBuilder — hyperlink rendering")
    struct HyperlinkRenderTests {
        @Test("linkURL encodes openURL as the URL and sendCommand via proteles-cmd:")
        func linkURLEncoding() {
            #expect(AttributedStringBuilder.linkURL(for: .openURL("http://x.io"))?
                .absoluteString == "http://x.io")
            #expect(AttributedStringBuilder.linkURL(for: .sendCommand("look"))?.absoluteString
                == "proteles-cmd:///look")
            // Spaces are percent-encoded so the command survives the URL.
            #expect(AttributedStringBuilder.linkURL(for: .sendCommand("look sign"))?.absoluteString
                == "proteles-cmd:///look%20sign")
        }

        @Test("A linked run gets a .link attribute over its range")
        func buildAttachesLink() {
            let builder = AttributedStringBuilder(
                palette: .xtermDefault,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular)
            )
            let link = LineLink(action: .openURL("http://x.io"))
            let line = Line(
                id: LineID(0),
                text: "go http://x.io",
                runs: [StyledRun(utf16Range: 3..<14, style: .default, link: link)]
            )
            let attributed = builder.build(line)
            var range = NSRange(location: 0, length: 0)
            let value = attributed.attribute(.link, at: 3, effectiveRange: &range)
            #expect((value as? URL)?.absoluteString == "http://x.io")
        }
    }
#endif

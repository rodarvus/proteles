#if os(macOS)
    import AppKit
    import MudCore
    @testable import MudUI
    import Testing

    @Suite("Channels AppKit log")
    struct ChatLogViewTests {
        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private let palette = Theme.default.palette

        @Test("Renders all channel rows into one selectable text storage")
        func rendersRowsIntoSingleTextStorage() {
            let lines = [
                chatLine(id: 0, text: "first"),
                chatLine(id: 1, text: "second")
            ]
            let string = builder.build(
                lines,
                showTimestamps: false,
                timestampSeconds: false
            )

            #expect(string.string == "first\nsecond\n")
        }

        @Test("Timestamp prefix is optional")
        func timestampPrefixIsOptional() {
            let date = Date(timeIntervalSince1970: 1_766_100_000)
            let lines = [chatLine(id: 0, timestamp: date, text: "market line")]
            let withTimestamp = builder.build(
                lines,
                showTimestamps: true,
                timestampSeconds: true
            )
            let withoutTimestamp = builder.build(
                lines,
                showTimestamps: false,
                timestampSeconds: true
            )

            #expect(withTimestamp.string.hasSuffix(" market line\n"))
            #expect(withoutTimestamp.string == "market line\n")
        }

        @Test("URL links survive the AppKit renderer")
        func urlLinksSurviveRenderer() {
            let url = "https://aardwolf.com"
            let style = StyleAttributes(underline: true)
            let run = StyledRun(
                utf16Range: 6..<26,
                style: style,
                link: LineLink(action: .openURL(url))
            )
            let lines = [chatLine(id: 0, text: "visit \(url)", runs: [run])]
            let string = builder.build(
                lines,
                showTimestamps: false,
                timestampSeconds: false
            )
            let link = string.attribute(.link, at: 6, effectiveRange: nil) as? URL
            let underline = string.attribute(
                .underlineStyle,
                at: 6,
                effectiveRange: nil
            ) as? Int

            #expect(link?.absoluteString == url)
            #expect(underline == NSUnderlineStyle.single.rawValue)
        }

        @Test("Bottom pin threshold matches main output semantics")
        func bottomPinThreshold() {
            #expect(ChatLogScrollView.isScrolledToBottom(
                documentHeight: 1000,
                visibleOriginY: 800,
                visibleHeight: 200,
                threshold: 32
            ))
            #expect(ChatLogScrollView.isScrolledToBottom(
                documentHeight: 1000,
                visibleOriginY: 770,
                visibleHeight: 200,
                threshold: 32
            ))
            #expect(!ChatLogScrollView.isScrolledToBottom(
                documentHeight: 1000,
                visibleOriginY: 760,
                visibleHeight: 200,
                threshold: 32
            ))
        }

        private var builder: ChatAttributedStringBuilder {
            ChatAttributedStringBuilder(
                palette: palette,
                font: font,
                timestampColor: .secondaryLabelColor
            )
        }

        private func chatLine(
            id: UInt64,
            timestamp: Date = Date(timeIntervalSince1970: 0),
            text: String,
            runs: [StyledRun] = []
        ) -> ChatLine {
            ChatLine(
                id: id,
                timestamp: timestamp,
                channel: "market",
                player: "",
                line: Line(id: LineID(id), text: text, runs: runs)
            )
        }
    }
#endif

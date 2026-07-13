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

            #expect(string.string == "first\nsecond")
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

            #expect(withTimestamp.string.hasSuffix(" market line"))
            #expect(withoutTimestamp.string == "market line")
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

        @Test("Health snapshot reports Channels geometry without text")
        @MainActor
        func healthSnapshotReportsChannelsGeometryWithoutText() {
            let scrollView = ChatLogScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            let textView = ChatLogTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
            textView.string = "first\nsecond"
            scrollView.documentView = textView

            let snapshot = scrollView.healthSnapshot(
                reason: "unit",
                renderedLines: 2,
                storageUTF16Length: textView.textStorage?.length ?? 0
            )
            let note = snapshot.transcriptNote(context: "unit")

            #expect(snapshot.surface == "channels")
            #expect(snapshot.renderedLines == 2)
            #expect(snapshot.storageUTF16Length == textView.textStorage?.length)
            #expect(note.contains("text-health: channels unit"))
            #expect(!note.contains("first"))
            #expect(!note.contains("second"))
        }

        @Test("Bottom settlement reaches exact Channels document geometry")
        @MainActor
        func bottomSettlementReachesExactGeometry() async throws {
            let scrollView = ChatLogScrollView(
                frame: NSRect(x: 0, y: 0, width: 400, height: 200)
            )
            let textView = ChatLogTextView(
                frame: NSRect(x: 0, y: 0, width: 400, height: 600)
            )
            scrollView.documentView = textView
            scrollView.contentView.scroll(to: .zero)

            scrollView.scrollToBottomSoon()
            try await Task.sleep(for: .milliseconds(50))

            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let distance = documentHeight - scrollView.contentView.documentVisibleRect.maxY
            #expect(abs(distance) <= 1)
        }

        @Test("Diagnostics identify only real Channels content transitions")
        @MainActor
        func diagnosticsIdentifyOnlyRealChannelsContentTransitions() {
            let coordinator = ChatLogView.Coordinator()

            #expect(coordinator.diagnosticTransition(
                lineCount: 2, storageUTF16Length: 12, filterKey: "all"
            ) == 1)
            #expect(coordinator.diagnosticTransition(
                lineCount: 2, storageUTF16Length: 12, filterKey: "all"
            ) == nil)
            #expect(coordinator.diagnosticTransition(
                lineCount: 2, storageUTF16Length: 12, filterKey: "tells"
            ) == 2)
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

#if os(macOS)
    import AppKit
    import CoreText
    import MudCore
    import SwiftUI

    /// AppKit/TextKit chat log used on macOS so Channels selection and scrolling
    /// follow the same model as the main output instead of SwiftUI row selection.
    struct ChatLogView: NSViewRepresentable {
        let lines: [ChatLine]
        let palette: ColorPalette
        let showTimestamps: Bool
        let timestampSeconds: Bool
        let filterKey: String
        let fillOpacity: Double

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> ChatLogScrollView {
            let scrollView = ChatLogScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = fillOpacity > 0
            scrollView.backgroundColor = backgroundColor
            scrollView.identifier = NSUserInterfaceItemIdentifier("proteles.channels-output")
            scrollView.setAccessibilityIdentifier("channels-output-scroll")

            let textView = ChatLogTextView()
            textView.delegate = context.coordinator
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainerInset = NSSize(width: 10, height: 6)
            textView.configure(font: Self.baseFont, background: backgroundColor)
            textView.setAccessibilityIdentifier("channels-output")
            textView.setAccessibilityLabel("Channels output")
            scrollView.documentView = textView
            context.coordinator.textView = textView
            updateNSView(scrollView, context: context)
            return scrollView
        }

        func updateNSView(_ scrollView: ChatLogScrollView, context: Context) {
            scrollView.drawsBackground = fillOpacity > 0
            scrollView.backgroundColor = backgroundColor
            guard let textView = scrollView.documentView as? ChatLogTextView else { return }
            textView.configure(font: Self.baseFont, background: backgroundColor)

            let forceBottom = !context.coordinator.hasRendered
                || context.coordinator.lastFilterKey != filterKey
            let wasPinned = scrollView.isScrolledToBottom()
            let previousOrigin = scrollView.contentView.bounds.origin
            let builder = ChatAttributedStringBuilder(
                palette: palette,
                font: Self.baseFont,
                timestampColor: NSColor.secondaryLabelColor
            )
            let attributed = PerformanceProbe.shared.measure(
                "channels.build",
                events: lines.count,
                thresholdMS: 50
            ) {
                builder.build(
                    lines,
                    showTimestamps: showTimestamps,
                    timestampSeconds: timestampSeconds
                )
            }
            PerformanceProbe.shared.measure(
                "channels.set-text",
                events: lines.count,
                thresholdMS: 50
            ) {
                textView.textStorage?.setAttributedString(attributed)
            }
            context.coordinator.hasRendered = true
            context.coordinator.lastFilterKey = filterKey

            if forceBottom || wasPinned {
                PerformanceProbe.shared.measure(
                    "channels.scroll-bottom",
                    events: lines.count,
                    thresholdMS: 50
                ) {
                    scrollView.scrollToBottomSoon()
                }
            } else {
                PerformanceProbe.shared.measure(
                    "channels.restore-origin",
                    events: lines.count,
                    thresholdMS: 50
                ) {
                    scrollView.restoreVisibleOrigin(previousOrigin)
                }
            }
        }

        private static var baseFont: NSFont {
            .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        }

        private var backgroundColor: NSColor {
            NSColor(rgb: palette.defaultBackground)
                .withAlphaComponent(CGFloat(fillOpacity))
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            weak var textView: ChatLogTextView?
            var hasRendered = false
            var lastFilterKey = ""

            func textView(
                _: NSTextView,
                clickedOnLink link: Any,
                at _: Int
            ) -> Bool {
                guard let url = link as? URL else { return false }
                NSWorkspace.shared.open(url)
                return true
            }
        }
    }

    final class ChatLogTextView: NSTextView {
        func configure(font: NSFont, background: NSColor) {
            isEditable = false
            isSelectable = true
            isRichText = true
            allowsUndo = false
            drawsBackground = background.alphaComponent > 0
            backgroundColor = background
            self.font = font
            linkTextAttributes = [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        }
    }

    final class ChatLogScrollView: NSScrollView {
        var autoScrollThreshold: CGFloat = 32

        override func setFrameSize(_ newSize: NSSize) {
            let wasPinned = isScrolledToBottom()
            super.setFrameSize(newSize)
            if wasPinned {
                scrollToBottomSoon()
            }
        }

        func isScrolledToBottom() -> Bool {
            guard let documentView else { return true }
            let visible = contentView.documentVisibleRect
            return Self.isScrolledToBottom(
                documentHeight: documentView.frame.height,
                visibleOriginY: visible.origin.y,
                visibleHeight: visible.height,
                threshold: autoScrollThreshold
            )
        }

        nonisolated static func isScrolledToBottom(
            documentHeight: CGFloat,
            visibleOriginY: CGFloat,
            visibleHeight: CGFloat,
            threshold: CGFloat
        ) -> Bool {
            let distanceFromBottom = documentHeight - (visibleOriginY + visibleHeight)
            return distanceFromBottom < threshold
        }

        func scrollToBottomSoon() {
            scrollToBottom()
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottom()
            }
        }

        func restoreVisibleOrigin(_ origin: CGPoint) {
            let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
            contentView.scroll(to: CGPoint(x: origin.x, y: min(origin.y, maxY)))
            reflectScrolledClipView(contentView)
        }

        private func scrollToBottom() {
            (documentView as? NSTextView)?.scrollToEndOfDocument(nil)
        }
    }

    struct ChatAttributedStringBuilder {
        let palette: ColorPalette
        let font: NSFont
        let timestampColor: NSColor

        private var boldFont: NSFont {
            Self.font(font, withTraits: .bold)
        }

        private var italicFont: NSFont {
            Self.font(font, withTraits: .italic)
        }

        private var boldItalicFont: NSFont {
            Self.font(font, withTraits: [.bold, .italic])
        }

        func build(
            _ lines: [ChatLine],
            showTimestamps: Bool,
            timestampSeconds: Bool
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    result.append(NSAttributedString(string: "\n"))
                }
                result.append(build(
                    line,
                    showTimestamps: showTimestamps,
                    timestampSeconds: timestampSeconds
                ))
            }
            return result
        }

        private func build(
            _ chatLine: ChatLine,
            showTimestamps: Bool,
            timestampSeconds: Bool
        ) -> NSAttributedString {
            let prefix = showTimestamps ? "\(timestamp(chatLine.timestamp, seconds: timestampSeconds)) " : ""
            let text = prefix + chatLine.line.text
            let result = NSMutableAttributedString(string: text)
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            result.addAttribute(.font, value: font, range: fullRange)
            result.addAttribute(
                .foregroundColor,
                value: NSColor(rgb: palette.defaultForeground),
                range: fullRange
            )
            if !prefix.isEmpty {
                result.addAttribute(
                    .foregroundColor,
                    value: timestampColor,
                    range: NSRange(location: 0, length: (prefix as NSString).length)
                )
            }
            let offset = (prefix as NSString).length
            for run in chatLine.line.runs {
                let range = NSRange(
                    location: offset + run.utf16Range.lowerBound,
                    length: run.utf16Range.count
                )
                apply(style: run.style, link: run.link, to: result, range: range)
            }
            return result
        }

        private func apply(
            style: StyleAttributes,
            link: LineLink?,
            to attributed: NSMutableAttributedString,
            range: NSRange
        ) {
            attributed.addAttribute(.font, value: font(for: style), range: range)
            attributed.addAttribute(.ligature, value: 0, range: range)
            let fg = palette.resolveForeground(style.foreground, bold: style.bold)
            let bg = palette.resolveBackground(style.background)
            let (renderedFg, renderedBg) = style.reverse ? (bg, fg) : (fg, bg)
            attributed.addAttribute(.foregroundColor, value: NSColor(rgb: renderedFg), range: range)
            if style.background != nil || style.reverse {
                attributed.addAttribute(.backgroundColor, value: NSColor(rgb: renderedBg), range: range)
            }
            if style.underline {
                attributed.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            if let url = Self.linkURL(for: link?.action) {
                attributed.addAttribute(.link, value: url, range: range)
                attributed.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }

        private func font(for style: StyleAttributes) -> NSFont {
            switch (style.bold, style.italic) {
            case (false, false): font
            case (true, false): boldFont
            case (false, true): italicFont
            case (true, true): boldItalicFont
            }
        }

        private func timestamp(_ date: Date, seconds: Bool) -> String {
            let style = Date.FormatStyle.dateTime.hour().minute()
            return date.formatted(seconds ? style.second() : style)
        }

        private static func font(
            _ font: NSFont,
            withTraits traits: NSFontDescriptor.SymbolicTraits
        ) -> NSFont {
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }

        private static func linkURL(for action: LinkAction?) -> URL? {
            guard case .openURL(let string) = action else { return nil }
            return URL(string: string)
        }
    }

    private extension NSColor {
        convenience init(rgb: RGB) {
            self.init(
                srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1
            )
        }
    }
#endif

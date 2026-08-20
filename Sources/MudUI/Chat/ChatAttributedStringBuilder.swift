#if os(macOS)
    import AppKit
    import MudCore

    struct ChatBuiltDocument {
        let attributed: NSAttributedString
        let renderedLines: [ChatRenderedLineSpan]
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
            buildDocument(
                lines,
                showTimestamps: showTimestamps,
                timestampSeconds: timestampSeconds
            ).attributed
        }

        func buildDocument(
            _ lines: [ChatLine],
            showTimestamps: Bool,
            timestampSeconds: Bool
        ) -> ChatBuiltDocument {
            let result = NSMutableAttributedString()
            var renderedLines: [ChatRenderedLineSpan] = []
            renderedLines.reserveCapacity(lines.count)
            for line in lines {
                let attributed = buildLine(
                    line,
                    showTimestamps: showTimestamps,
                    timestampSeconds: timestampSeconds
                )
                if !renderedLines.isEmpty {
                    result.append(NSAttributedString(string: "\n"))
                    renderedLines[renderedLines.count - 1].utf16Length += 1
                }
                result.append(attributed)
                renderedLines.append(ChatRenderedLineSpan(
                    id: line.id,
                    utf16Length: attributed.length
                ))
            }
            return ChatBuiltDocument(attributed: result, renderedLines: renderedLines)
        }

        func buildLine(
            _ chatLine: ChatLine,
            showTimestamps: Bool,
            timestampSeconds: Bool
        ) -> NSAttributedString {
            let prefix = showTimestamps && chatLine.showsTimestamp
                ? "\(timestamp(chatLine.timestamp, seconds: timestampSeconds)) " : ""
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

    extension NSColor {
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

#if os(macOS)
    import AppKit
    import MudCore

    /// Renders a ``Line`` into an `NSAttributedString` suitable for appending
    /// to an `NSTextStorage`.
    ///
    /// Construction is per-view, not per-line: the builder caches the four
    /// font variants (regular / bold / italic / bold-italic) up front so the
    /// per-line work is just attribute assignment.
    ///
    /// Reverse video (SGR 7) is rendered by swapping the resolved foreground
    /// and background at attribute-application time. SGR 8 (conceal) is not
    /// honoured.
    public struct AttributedStringBuilder {
        public let palette: ColorPalette

        private let font: NSFont
        private let boldFont: NSFont
        private let italicFont: NSFont
        private let boldItalicFont: NSFont

        public init(palette: ColorPalette, font: NSFont) {
            self.palette = palette
            self.font = font
            boldFont = Self.font(font, withTraits: .bold)
            italicFont = Self.font(font, withTraits: .italic)
            boldItalicFont = Self.font(font, withTraits: [.bold, .italic])
        }

        /// Build an attributed string for `line`, ending with a single
        /// line-feed so that successive appends to `NSTextStorage` produce
        /// distinct visual lines.
        public func build(_ line: Line) -> NSAttributedString {
            let plain = line.text + "\n"
            let result = NSMutableAttributedString(string: plain)
            let fullRange = NSRange(location: 0, length: (plain as NSString).length)

            // Default attributes for the whole line, overridden by run-level
            // attributes below.
            result.addAttribute(.font, value: font, range: fullRange)
            result.addAttribute(
                .foregroundColor,
                value: NSColor(palette.defaultForeground),
                range: fullRange
            )

            for run in line.runs {
                let nsRange = NSRange(
                    location: run.utf16Range.lowerBound,
                    length: run.utf16Range.count
                )
                apply(style: run.style, to: result, range: nsRange)
                if let link = run.link {
                    Self.applyLink(link, to: result, range: nsRange)
                }
            }

            return result
        }

        // MARK: - Private

        private func apply(
            style: StyleAttributes,
            to attributed: NSMutableAttributedString,
            range: NSRange
        ) {
            // Stash the original StyleAttributes so "Copy with Colour
            // Codes" can read it back without lossy NSColor inversion.
            attributed.addAttribute(
                .protelesStyle,
                value: ProtelesStyleAttribute(style),
                range: range
            )

            let effectiveFont: NSFont = switch (style.bold, style.italic) {
            case (false, false): font
            case (true, false): boldFont
            case (false, true): italicFont
            case (true, true): boldItalicFont
            }
            attributed.addAttribute(.font, value: effectiveFont, range: range)

            let fg = palette.resolveForeground(style.foreground, bold: style.bold)
            let bg = palette.resolveBackground(style.background)
            let (renderedFg, renderedBg) = style.reverse ? (bg, fg) : (fg, bg)

            attributed.addAttribute(
                .foregroundColor,
                value: NSColor(renderedFg),
                range: range
            )
            if style.background != nil || style.reverse {
                attributed.addAttribute(
                    .backgroundColor,
                    value: NSColor(renderedBg),
                    range: range
                )
            }

            if style.underline {
                attributed.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }

            if style.strikethrough {
                attributed.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }

        /// Make `range` a clickable hyperlink: an `.link` carrying the action
        /// (`proteles-cmd:` for send-command, the URL itself for open-URL),
        /// underlined, with the hint as a tooltip. `MudTextView`'s delegate
        /// decodes the link on click.
        private static func applyLink(
            _ link: LineLink,
            to attributed: NSMutableAttributedString,
            range: NSRange
        ) {
            guard let url = linkURL(for: link.action) else { return }
            attributed.addAttribute(.link, value: url, range: range)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            if let hint = link.hint {
                attributed.addAttribute(.toolTip, value: hint, range: range)
            }
        }

        /// Encode a ``LinkAction`` as a URL for the `.link` attribute. A
        /// send-command action uses the custom `proteles-cmd:` scheme so the
        /// text view's delegate can route it back to the session.
        static func linkURL(for action: LinkAction) -> URL? {
            switch action {
            case .openURL(let string):
                return URL(string: string)
            case .sendCommand(let command):
                let encoded = command.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? ""
                return URL(string: "proteles-cmd:///\(encoded)")
            }
        }

        private static func font(
            _ font: NSFont,
            withTraits traits: NSFontDescriptor.SymbolicTraits
        ) -> NSFont {
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
    }
#endif

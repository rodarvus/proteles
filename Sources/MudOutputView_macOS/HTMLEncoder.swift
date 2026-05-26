#if os(macOS)
    import AppKit
    import MudCore

    /// Re-encodes a styled selection as **HTML** — the "Copy as HTML" path
    /// (backlog #2, completing `aard_Copy_Colour_Codes`'s formats). Each styled
    /// run becomes a `<span style="color:#RRGGBB[;font-weight:bold]…">…</span>`;
    /// colours resolve through the same ``ColorPalette`` the renderer uses, so
    /// the markup matches what's on screen. The whole result is wrapped in
    /// `<pre>` so MUD whitespace/newlines (maps, tables, prompts) survive paste.
    ///
    /// Mirrors ``SGREncoder``/``AardwolfCodeEncoder``: an `NSAttributedString`
    /// entry (reads ``NSAttributedString/Key/protelesStyle``) plus a ``Line``
    /// entry (used by tests). The markup is placed on the pasteboard as a string
    /// (paste the source into a forum/blog/editor), consistent with the ANSI and
    /// Aardwolf copy actions.
    public struct HTMLEncoder {
        private let palette: ColorPalette

        public init(palette: ColorPalette = .xtermDefault) {
            self.palette = palette
        }

        public func encode(_ attributedString: NSAttributedString) -> String {
            let length = attributedString.length
            guard length > 0 else { return "" }

            var body = ""
            var index = 0
            while index < length {
                var effectiveRange = NSRange(location: 0, length: 0)
                let style = attributedString.attribute(
                    .protelesStyle, at: index, effectiveRange: &effectiveRange
                ) as? ProtelesStyleAttribute
                let substring = attributedString.attributedSubstring(
                    from: NSRange(location: effectiveRange.location, length: effectiveRange.length)
                )
                body += span(style?.value ?? .default, around: substring.string)
                index = effectiveRange.location + effectiveRange.length
            }
            return wrap(body)
        }

        /// Convenience for direct ``Line`` input (tests, or any caller with a
        /// Line). Gaps between runs are default-styled (no span).
        public func encode(_ line: Line) -> String {
            guard !line.text.isEmpty else { return "" }
            var body = ""
            let utf16 = Array(line.text.utf16)

            var cursor = 0
            for run in line.runs {
                if run.utf16Range.lowerBound > cursor {
                    body += span(.default, around: Self.substring(utf16, cursor, run.utf16Range.lowerBound))
                }
                body += span(run.style, around: Self.substring(
                    utf16, run.utf16Range.lowerBound, run.utf16Range.upperBound
                ))
                cursor = run.utf16Range.upperBound
            }
            if cursor < utf16.count {
                body += span(.default, around: Self.substring(utf16, cursor, utf16.count))
            }
            return wrap(body)
        }

        // MARK: - Private

        private func wrap(_ body: String) -> String {
            body.isEmpty ? "" : "<pre>\(body)</pre>"
        }

        /// Wrap `text` (HTML-escaped) in a `<span>` carrying the run's colour /
        /// bold / underline; plain (default) runs get no span.
        private func span(_ style: StyleAttributes, around text: String) -> String {
            guard !text.isEmpty else { return "" }
            let escaped = Self.escape(text)
            var rules: [String] = []
            if let foreground = style.foreground {
                rules.append("color:#" + Self.hex(palette.resolveForeground(foreground)))
            }
            if style.bold { rules.append("font-weight:bold") }
            if style.underline { rules.append("text-decoration:underline") }
            guard !rules.isEmpty else { return escaped }
            return "<span style=\"\(rules.joined(separator: ";"))\">\(escaped)</span>"
        }

        private static func hex(_ rgb: RGB) -> String {
            String(format: "%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
        }

        private static func escape(_ text: String) -> String {
            text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        private static func substring(_ utf16: [UInt16], _ from: Int, _ to: Int) -> String {
            String(decoding: utf16[from..<to], as: UTF16.self)
        }
    }
#endif

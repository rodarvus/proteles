#if os(macOS)
    import AppKit
    import MudCore

    /// Re-encodes styled text as a plain string with ANSI SGR escape
    /// sequences inlined at run boundaries. The "Copy with Colour Codes"
    /// path (matching the `aard_Copy_Colour_Codes` MUSHclient plugin)
    /// pipes the user's selection through this encoder before placing it
    /// on the pasteboard, so users can paste fully-coloured snippets into
    /// forums, Discord, or another MUD client.
    ///
    /// Style boundaries are detected by reading
    /// ``NSAttributedString/Key/protelesStyle`` — set by
    /// ``AttributedStringBuilder``. Anywhere that attribute is missing the
    /// encoder treats the text as default-styled, so plain pasted text and
    /// programmatic insertions degrade gracefully.
    ///
    /// Format choice — at each style change the encoder emits a "reset +
    /// apply" sequence (`\e[0;1;31m`). It's a few extra bytes but
    /// idempotent and trivially safe to paste anywhere; lots of MUD-
    /// targeted tools normalise on this form.
    public struct SGREncoder {
        public init() {}

        /// Encode `attributedString` to a string with SGR codes preserving
        /// its ``StyleAttributes`` runs. Always terminates with a final
        /// `\e[0m` reset if any styled run was emitted.
        public func encode(_ attributedString: NSAttributedString) -> String {
            let length = attributedString.length
            guard length > 0 else { return "" }

            var result = ""
            var hasEmittedStyled = false
            var lastEmittedStyle: StyleAttributes = .default

            var index = 0
            while index < length {
                var effectiveRange = NSRange(location: 0, length: 0)
                let style = attributedString.attribute(
                    .protelesStyle,
                    at: index,
                    effectiveRange: &effectiveRange
                ) as? ProtelesStyleAttribute

                let runStart = effectiveRange.location
                let runLength = effectiveRange.length
                let runStyle = style?.value ?? .default

                // Apply the run's style if it differs from the last
                // emitted one. (Always emits when the run is non-default
                // and is the first styled run.)
                if runStyle != lastEmittedStyle {
                    result += Self.sgrTransition(to: runStyle)
                    lastEmittedStyle = runStyle
                    if !runStyle.isDefault { hasEmittedStyled = true }
                }

                let substring = attributedString.attributedSubstring(
                    from: NSRange(location: runStart, length: runLength)
                )
                result += substring.string

                index = runStart + runLength
            }

            // Final reset if we ever wrote a non-default style — leaving
            // the terminal "open" would bleed our colours into whatever
            // text the user pastes alongside.
            if hasEmittedStyled, lastEmittedStyle != .default {
                result += "\u{1B}[0m"
            }

            return result
        }

        /// Convenience for direct ``Line`` input, used by tests and by
        /// any caller that already has a Line to render.
        public func encode(_ line: Line) -> String {
            var result = ""
            var lastEmitted: StyleAttributes = .default

            let utf16 = Array(line.text.utf16)

            // We walk through line.runs in order; gaps between runs are
            // default-styled.
            var cursor = 0
            for run in line.runs {
                let start = run.utf16Range.lowerBound
                let end = run.utf16Range.upperBound
                if start > cursor {
                    // Default-styled gap.
                    if lastEmitted != .default {
                        result += "\u{1B}[0m"
                        lastEmitted = .default
                    }
                    result += Self.utf16Substring(utf16, from: cursor, to: start)
                    cursor = start
                }
                if run.style != lastEmitted {
                    result += Self.sgrTransition(to: run.style)
                    lastEmitted = run.style
                }
                result += Self.utf16Substring(utf16, from: start, to: end)
                cursor = end
            }
            if cursor < utf16.count {
                if lastEmitted != .default {
                    result += "\u{1B}[0m"
                    lastEmitted = .default
                }
                result += Self.utf16Substring(utf16, from: cursor, to: utf16.count)
            }

            if lastEmitted != .default {
                result += "\u{1B}[0m"
            }
            return result
        }

        // MARK: - Private

        private static func utf16Substring(
            _ utf16: [UInt16],
            from: Int,
            to: Int
        ) -> String {
            let slice = utf16[from..<to]
            return String(decoding: Array(slice), as: UTF16.self)
        }

        /// Build the SGR sequence that transitions from "whatever was set"
        /// to `style`. Emits a leading reset (SGR 0) so the output is
        /// idempotent regardless of preceding context.
        private static func sgrTransition(to style: StyleAttributes) -> String {
            if style.isDefault {
                return "\u{1B}[0m"
            }

            var codes = [0]
            if style.bold { codes.append(1) }
            if style.dim { codes.append(2) }
            if style.italic { codes.append(3) }
            if style.underline { codes.append(4) }
            if style.reverse { codes.append(7) }
            if style.strikethrough { codes.append(9) }

            if let foreground = style.foreground {
                codes.append(contentsOf: foregroundCodes(for: foreground))
            }
            if let background = style.background {
                codes.append(contentsOf: backgroundCodes(for: background))
            }

            return "\u{1B}[" + codes.map(String.init).joined(separator: ";") + "m"
        }

        private static func foregroundCodes(for color: ANSIColor) -> [Int] {
            switch color {
            case .named(let named):
                [30 + Int(named.rawValue)]
            case .brightNamed(let named):
                [90 + Int(named.rawValue)]
            case .palette(let index):
                [38, 5, Int(index)]
            case .rgb(let red, let green, let blue):
                [38, 2, Int(red), Int(green), Int(blue)]
            }
        }

        private static func backgroundCodes(for color: ANSIColor) -> [Int] {
            switch color {
            case .named(let named):
                [40 + Int(named.rawValue)]
            case .brightNamed(let named):
                [100 + Int(named.rawValue)]
            case .palette(let index):
                [48, 5, Int(index)]
            case .rgb(let red, let green, let blue):
                [48, 2, Int(red), Int(green), Int(blue)]
            }
        }
    }
#endif

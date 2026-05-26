#if os(macOS)
    import AppKit
    import MudCore

    /// Re-encodes a styled selection as **Aardwolf `@`-colour codes** — the
    /// "Copy as Aardwolf Colour Codes" path (native equivalent of
    /// `aard_Copy_Colour_Codes` / our `StylesToColours`). A code is emitted at
    /// each run boundary and a literal `@` in the text is doubled to `@@`, so
    /// the result pastes faithfully into Aardwolf notes/forum/channels or to
    /// another Aardwolf player.
    ///
    /// Mirrors ``SGREncoder`` (the ANSI sibling): both an `NSAttributedString`
    /// entry (reads ``NSAttributedString/Key/protelesStyle``) and a ``Line``
    /// entry (used by tests). Colour mapping:
    /// - `.named` → lowercase `@r` (or uppercase when bold = bright),
    /// - `.brightNamed` → uppercase `@R`,
    /// - `.palette(n)` → `@xNNN` (Aardwolf's xterm code is the palette index),
    /// - `.rgb` → exact-16 match → named code, else nearest xterm-256 → `@xNNN`,
    /// - default/no colour → `@w` (Aardwolf normal white, matching the
    ///   reference where a default run carries white `0xAAAAAA`).
    ///
    /// This preserves 256-colour content via `@x` — a small improvement over the
    /// reference's `StylesToColours`, which only maps the 16 named colours.
    public struct AardwolfCodeEncoder {
        public init() {}

        public func encode(_ attributedString: NSAttributedString) -> String {
            let length = attributedString.length
            guard length > 0 else { return "" }

            var result = ""
            var lastCode: String?
            var index = 0
            while index < length {
                var effectiveRange = NSRange(location: 0, length: 0)
                let style = attributedString.attribute(
                    .protelesStyle, at: index, effectiveRange: &effectiveRange
                ) as? ProtelesStyleAttribute
                let runStyle = style?.value ?? .default

                let code = Self.code(for: runStyle)
                if code != lastCode, !(code == "@w" && lastCode == nil) {
                    result += code
                    lastCode = code
                }
                let substring = attributedString.attributedSubstring(
                    from: NSRange(location: effectiveRange.location, length: effectiveRange.length)
                )
                result += Self.escape(substring.string)
                index = effectiveRange.location + effectiveRange.length
            }
            return result
        }

        /// Convenience for direct ``Line`` input (tests, or any caller with a
        /// Line). Gaps between runs are default-styled (`@w`).
        public func encode(_ line: Line) -> String {
            var result = ""
            var lastCode: String?
            let utf16 = Array(line.text.utf16)

            func emit(_ style: StyleAttributes, from start: Int, to end: Int) {
                guard start < end else { return }
                let code = Self.code(for: style)
                // Suppress a leading "@w" (no colour emitted yet); keep it only
                // as a reset after a coloured run.
                if code != lastCode, !(code == "@w" && lastCode == nil) {
                    result += code
                    lastCode = code
                }
                result += Self.escape(Self.utf16Substring(utf16, from: start, to: end))
            }

            var cursor = 0
            for run in line.runs {
                if run.utf16Range.lowerBound > cursor {
                    emit(.default, from: cursor, to: run.utf16Range.lowerBound)
                }
                emit(run.style, from: run.utf16Range.lowerBound, to: run.utf16Range.upperBound)
                cursor = run.utf16Range.upperBound
            }
            if cursor < utf16.count {
                emit(.default, from: cursor, to: utf16.count)
            }
            return result
        }

        // MARK: - Private

        /// The `@`-code for a run's foreground (`@w` when default/none).
        static func code(for style: StyleAttributes) -> String {
            switch style.foreground {
            case .none:
                "@w"
            case .named(let colour):
                "@" + namedCode(colour, bright: style.bold)
            case .brightNamed(let colour):
                "@" + namedCode(colour, bright: true)
            case .palette(let index):
                xtermCode(Int(index))
            case .rgb(let red, let green, let blue):
                rgbCode(red, green, blue)
            }
        }

        private static func namedCode(_ colour: NamedColor, bright: Bool) -> String {
            let lower: Character = switch colour {
            case .black: "k"
            case .red: "r"
            case .green: "g"
            case .yellow: "y"
            case .blue: "b"
            case .magenta: "m"
            case .cyan: "c"
            case .white: "w"
            }
            return String(bright ? Character(lower.uppercased()) : lower)
        }

        private static func xtermCode(_ index: Int) -> String {
            String(format: "@x%03d", max(0, min(255, index)))
        }

        /// An 8-bit RGB triple (a struct, to avoid a 3-member tuple).
        private struct RGB: Equatable {
            let r: UInt8, g: UInt8, b: UInt8
        }

        /// Exact match to one of the 16 named RGBs → that named code; otherwise
        /// the nearest xterm-256 palette index as `@xNNN`.
        private static func rgbCode(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> String {
            let target = RGB(r: red, g: green, b: blue)
            for (index, entry) in named16.enumerated() where entry.rgb == target {
                return "@" + namedCode(entry.colour, bright: index >= 8)
            }
            return xtermCode(nearestXterm(target))
        }

        /// The 16 ANSI colours with their RGBs (normal 0–7, bright 8–15),
        /// matching our `aardwolf_colors` table.
        private static let named16: [(rgb: RGB, colour: NamedColor)] = [
            (RGB(r: 0, g: 0, b: 0), .black), (RGB(r: 0xAA, g: 0, b: 0), .red),
            (RGB(r: 0, g: 0xAA, b: 0), .green), (RGB(r: 0xAA, g: 0xAA, b: 0), .yellow),
            (RGB(r: 0, g: 0, b: 0xAA), .blue), (RGB(r: 0xAA, g: 0, b: 0xAA), .magenta),
            (RGB(r: 0, g: 0xAA, b: 0xAA), .cyan), (RGB(r: 0xAA, g: 0xAA, b: 0xAA), .white),
            (RGB(r: 0x55, g: 0x55, b: 0x55), .black), (RGB(r: 0xFF, g: 0x55, b: 0x55), .red),
            (RGB(r: 0x55, g: 0xFF, b: 0x55), .green), (RGB(r: 0xFF, g: 0xFF, b: 0x55), .yellow),
            (RGB(r: 0x55, g: 0x55, b: 0xFF), .blue), (RGB(r: 0xFF, g: 0x55, b: 0xFF), .magenta),
            (RGB(r: 0x55, g: 0xFF, b: 0xFF), .cyan), (RGB(r: 0xFF, g: 0xFF, b: 0xFF), .white)
        ]

        /// Nearest xterm-256 index (16–255: the 6×6×6 cube + grayscale ramp) to
        /// an RGB by squared distance.
        private static func nearestXterm(_ target: RGB) -> Int {
            var best = 16
            var bestDistance = Int.max
            for index in 16...255 {
                let palette = paletteRGB(index)
                let dr = Int(target.r) - Int(palette.r)
                let dg = Int(target.g) - Int(palette.g)
                let db = Int(target.b) - Int(palette.b)
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            return best
        }

        /// RGB of xterm palette index 16–255 (6×6×6 cube, then grayscale).
        private static func paletteRGB(_ index: Int) -> RGB {
            if index >= 232 {
                let gray = UInt8((index - 232) * 10 + 8)
                return RGB(r: gray, g: gray, b: gray)
            }
            let cube = index - 16
            func level(_ value: Int) -> UInt8 {
                value == 0 ? 0 : UInt8(value * 40 + 55)
            }
            return RGB(r: level((cube / 36) % 6), g: level((cube / 6) % 6), b: level(cube % 6))
        }

        private static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "@", with: "@@")
        }

        private static func utf16Substring(_ utf16: [UInt16], from: Int, to: Int) -> String {
            String(decoding: utf16[from..<to], as: UTF16.self)
        }
    }
#endif

#if os(macOS)
    import AppKit
    import CoreGraphics

    public extension MudOutputView {
        /// The character grid (columns × rows) that fits `size` points using the
        /// output font — for NAWS window-size reporting (telnet option 31).
        /// Resolves the font the same way ``baseFont`` does (named family, else
        /// the system monospaced font); the cell width is a digit's advance
        /// (the font is monospaced) and the row height the layout-manager line
        /// height. Clamped to at least 1×1.
        static func characterGrid(
            for size: CGSize, fontName: String, fontSize: CGFloat
        ) -> (columns: Int, rows: Int) {
            let font = (fontName.isEmpty ? nil : NSFont(name: fontName, size: fontSize))
                ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let cellWidth = NSAttributedString(string: "0", attributes: [.font: font]).size().width
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            guard cellWidth > 0, lineHeight > 0 else { return (1, 1) }
            return (
                columns: max(1, Int((size.width / cellWidth).rounded(.down))),
                rows: max(1, Int((size.height / lineHeight).rounded(.down)))
            )
        }
    }
#endif

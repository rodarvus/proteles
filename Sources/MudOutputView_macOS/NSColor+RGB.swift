#if os(macOS)
    import AppKit
    import MudCore

    extension NSColor {
        /// Construct an sRGB `NSColor` from a MudCore ``RGB`` triple.
        /// Alpha is always 1.0.
        convenience init(_ rgb: RGB) {
            self.init(
                srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1
            )
        }
    }
#endif

import MudCore
import SwiftUI

extension Line {
    /// Render this line as a SwiftUI `AttributedString`, resolving each
    /// styled run's foreground colour through `palette`. Spans without an
    /// explicit run use the default text colour. Bold/italic/underline
    /// flags are applied where set.
    func attributedText(palette: ColorPalette = .xtermDefault) -> AttributedString {
        var result = AttributedString(text)
        for run in runs {
            guard let range = attributedRange(run.utf16Range, in: result) else { continue }
            let style = run.style
            if let foreground = style.foreground {
                let rgb = palette.resolve(foreground)
                result[range].foregroundColor = Color(
                    .sRGB,
                    red: Double(rgb.red) / 255,
                    green: Double(rgb.green) / 255,
                    blue: Double(rgb.blue) / 255
                )
            }
            if style.bold {
                // Bold via presentation intent (not an absolute font) so it
                // inherits the view's base font — keeping monospaced text
                // monospaced (the map/chat align by column).
                result[range].inlinePresentationIntent = .stronglyEmphasized
            }
            if style.underline {
                result[range].underlineStyle = .single
            }
            // Clickable spans (URL auto-linkify): SwiftUI `Text` opens a
            // `.link` attribute in the browser on click. Command links have
            // no SwiftUI handler here, so only real URLs map.
            if case .openURL(let urlString)? = run.link?.action {
                if let url = URL(string: urlString) {
                    result[range].link = url
                    result[range].underlineStyle = .single
                }
            }
        }
        return result
    }

    /// Convert a UTF-16 offset range over ``text`` into an
    /// `AttributedString` index range.
    private func attributedRange(
        _ utf16Range: Range<Int>,
        in attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard
            let lower = stringIndex(atUTF16Offset: utf16Range.lowerBound),
            let upper = stringIndex(atUTF16Offset: utf16Range.upperBound)
        else { return nil }
        return Range(lower..<upper, in: attributed)
    }

    private func stringIndex(atUTF16Offset offset: Int) -> String.Index? {
        let utf16 = text.utf16
        guard let utf16Index = utf16.index(
            utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex
        ) else { return nil }
        return utf16Index.samePosition(in: text)
    }
}

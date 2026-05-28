import Foundation

/// Output format for a user session log.
public enum SessionLogFormat: String, Sendable, Codable, CaseIterable {
    /// Plain text — ANSI/colour stripped (just ``Line/text``). Readable anywhere.
    case text
    /// HTML — a `<pre>` document with `<span>` colour runs (palette-resolved
    /// hex), so colours survive out of context. Like Mudlet's HTML log.
    case html
}

/// Pure conversion of a ``Line`` to a log representation (text or HTML). No file
/// I/O, no UI — so it's unit-testable. Used by ``SessionLogger`` to write each
/// finalized line as it scrolls by.
public enum SessionLogFormatter {
    /// The plain-text rendering of a line (no trailing newline).
    public static func text(_ line: Line) -> String {
        line.text
    }

    /// The HTML rendering of a single line's content (no trailing newline):
    /// styled runs become `<span style="color:#…">`, gaps render plain, HTML is
    /// escaped. Colours resolve through `palette` (foreground only; bold kept).
    public static func htmlLine(_ line: Line, palette: ColorPalette) -> String {
        let nsText = line.text as NSString
        let length = nsText.length
        guard length > 0 else { return "" }

        var points: Set<Int> = [0, length]
        for run in line.runs {
            points.insert(run.utf16Range.lowerBound)
            points.insert(run.utf16Range.upperBound)
        }
        let sorted = points.sorted()

        var html = ""
        for index in 0..<(sorted.count - 1) {
            let start = sorted[index], end = sorted[index + 1]
            guard start < end else { continue }
            let slice = escape(nsText.substring(with: NSRange(location: start, length: end - start)))
            let style = line.runs.first { $0.utf16Range.contains(start) }?.style
            html += span(slice, style: style, palette: palette)
        }
        return html
    }

    /// The opening of an HTML log document (dark `<pre>` matching the palette's
    /// default fg/bg).
    public static func htmlHeader(palette: ColorPalette) -> String {
        let bg = hex(palette.defaultBackground)
        let fg = hex(palette.defaultForeground)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Proteles session log</title></head>
        <body style="background:#\(bg);color:#\(fg);margin:0;padding:12px;">
        <pre style="font-family:Menlo,Monaco,monospace;font-size:13px;white-space:pre-wrap;line-height:1.3;">

        """
    }

    /// The closing of an HTML log document.
    public static let htmlFooter = "</pre></body></html>\n"

    // MARK: - Helpers

    private static func span(_ text: String, style: StyleAttributes?, palette: ColorPalette) -> String {
        guard let style, !style.isDefault else { return text }
        var css: [String] = []
        if let foreground = style.foreground {
            css.append("color:#\(hex(palette.resolveForeground(foreground)))")
        }
        if style.bold { css.append("font-weight:bold") }
        if style.italic { css.append("font-style:italic") }
        if style.underline { css.append("text-decoration:underline") }
        guard !css.isEmpty else { return text }
        return "<span style=\"\(css.joined(separator: ";"))\">\(text)</span>"
    }

    private static func hex(_ rgb: RGB) -> String {
        String(format: "%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

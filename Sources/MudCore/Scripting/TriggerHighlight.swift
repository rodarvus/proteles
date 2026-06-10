import Foundation

/// A trigger's restyle-on-match (D-105): recolour (and optionally embolden)
/// the matched text or the whole line. The deliberate Aardwolf subset of
/// MUSHclient's "change colour and style to" — one foreground colour + bold,
/// not the full fore/back/italic/underline matrix.
///
/// This is *user-directed* recolouring, which DESIGN.md §3.1 ("the MUD owns
/// its colour") permits: the player chose this colour for this line; the
/// app still never recolours game text for its own purposes.
public struct TriggerHighlight: Sendable, Equatable, Codable {
    public enum Scope: String, Sendable, Equatable, Codable {
        /// Restyle just the span the pattern matched.
        case matchedText
        /// Restyle the entire line.
        case wholeLine
    }

    public var foreground: ANSIColor
    public var bold: Bool
    public var scope: Scope

    public init(
        foreground: ANSIColor,
        bold: Bool = false,
        scope: Scope = .wholeLine
    ) {
        self.foreground = foreground
        self.bold = bold
        self.scope = scope
    }
}

/// Applies a ``TriggerHighlight`` to a ``Line``, producing the restyled line
/// the session displays instead (via `LineDisposition.replacement`). Pure.
public enum LineHighlighter {
    /// Restyle `line`. `matchRange` (UTF-16, from the pattern match) bounds a
    /// `.matchedText` highlight; pass nil to force the whole line (also the
    /// fallback when the matched span is unknown).
    public static func apply(
        _ highlight: TriggerHighlight,
        to line: Line,
        matchRange: Range<Int>?
    ) -> Line {
        let length = line.text.utf16.count
        guard length > 0 else { return line }
        let target: Range<Int> = switch highlight.scope {
        case .wholeLine: 0..<length
        case .matchedText: (matchRange ?? 0..<length).clamped(to: 0..<length)
        }
        guard !target.isEmpty else { return line }

        // Segment the line at every style boundary + the target's edges, so
        // each segment has one source style (a covering run, else default)
        // and is either fully inside or fully outside the target range.
        var boundaries: Set<Int> = [0, length, target.lowerBound, target.upperBound]
        for run in line.runs {
            boundaries.insert(run.utf16Range.lowerBound)
            boundaries.insert(run.utf16Range.upperBound)
        }
        let cuts = boundaries.filter { (0...length).contains($0) }.sorted()

        var runs: [StyledRun] = []
        for (start, end) in zip(cuts, cuts.dropFirst()) where start < end {
            let source = line.runs.first { $0.utf16Range.contains(start) }
            var style = source?.style ?? .default
            if target.contains(start) {
                style.foreground = highlight.foreground
                style.bold = style.bold || highlight.bold
            }
            // Keep hyperlinks clickable through a restyle.
            runs.append(StyledRun(utf16Range: start..<end, style: style, link: source?.link))
        }
        return Line(id: line.id, timestamp: line.timestamp, text: line.text, runs: runs)
    }
}

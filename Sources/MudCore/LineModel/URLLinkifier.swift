import Foundation

/// Detects URLs in a ``Line`` and marks the covering spans as ``LineLink``
/// hyperlinks (`.openURL`), preserving the line's existing styling — the
/// native equivalent of `aard_Copy_Colour_Codes`'s sibling `Hyperlink_URL2`.
///
/// Pure and value-typed (no UI): the macOS renderer turns linked runs into
/// clickable text. Splits existing runs at URL boundaries so a URL that spans
/// a colour change still becomes a single logical link on each slice.
public enum URLLinkifier {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Return `line` with URL substrings marked as `.openURL` links. Unchanged
    /// (same value) when it contains no URLs.
    public static func linkify(_ line: Line) -> Line {
        let nsText = line.text as NSString
        let length = nsText.length
        guard length > 0, let detector else { return line }

        let matches = detector.matches(in: line.text, range: NSRange(location: 0, length: length))
        let urlRanges = matches.compactMap { match -> (Range<Int>, String)? in
            guard match.resultType == .link else { return nil }
            let range = match.range.lowerBound..<match.range.upperBound
            return (range, nsText.substring(with: match.range))
        }
        guard !urlRanges.isEmpty else { return line }

        // Boundary points: line ends, every run edge, every URL edge.
        var points: Set<Int> = [0, length]
        for run in line.runs {
            points.insert(run.utf16Range.lowerBound)
            points.insert(run.utf16Range.upperBound)
        }
        for (range, _) in urlRanges {
            points.insert(range.lowerBound)
            points.insert(range.upperBound)
        }
        let sorted = points.sorted()

        var runs: [StyledRun] = []
        for index in 0..<(sorted.count - 1) {
            let start = sorted[index], end = sorted[index + 1]
            guard start < end else { continue }
            let style = style(at: start, in: line.runs)
            let link = urlRanges.first { $0.0.contains(start) }.map { LineLink(action: .openURL($0.1)) }
            // Keep runs minimal: emit only styled or linked slices.
            if !style.isDefault || link != nil {
                runs.append(StyledRun(utf16Range: start..<end, style: style, link: link))
            }
        }
        return Line(id: line.id, timestamp: line.timestamp, text: line.text, runs: runs)
    }

    /// The style covering `index` in `runs` (default when none).
    private static func style(at index: Int, in runs: [StyledRun]) -> StyleAttributes {
        runs.first { $0.utf16Range.contains(index) }?.style ?? .default
    }
}

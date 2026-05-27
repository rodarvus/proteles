import Foundation

/// A captured Aardwolf help article: the styled body lines (with clickable
/// cross-reference links already applied) plus a best-effort title. Published
/// to the Help panel.
public struct HelpArticle: Sendable, Equatable {
    /// Best-effort heading (the first non-empty body line, stripped).
    public var title: String
    /// The help body, one styled ``Line`` per row. "Related Helps" topics carry
    /// `.sendCommand("help <topic>")` links.
    public var lines: [Line]
    /// True when this came from `help search …` rather than `help <topic>`.
    public var isSearch: Bool

    public init(title: String, lines: [Line], isSearch: Bool) {
        self.title = title
        self.lines = lines
        self.isSearch = isSearch
    }
}

/// Pure logic for the **Help** feature: detect Aardwolf's `{help}…{/help}`
/// (and `{helpsearch}…{/helpsearch}`) tag boundaries and turn help
/// cross-references into clickable `help <topic>` links. Independent
/// reimplementation of `aard_ingame_help_window` (Fiendish), which captures the
/// same tagged block to a miniwindow; here the controller buffers the block and
/// publishes a ``HelpArticle`` to a native panel.
///
/// The tag lines themselves are markers only (the reference matches `^{help}$`
/// etc. and ignores their content); the body is everything between them.
public enum HelpParser {
    /// If `text` opens a help block, whether it's a `help search` block;
    /// `nil` when `text` isn't an opening help tag.
    public static func openTag(_ text: String) -> Bool? {
        switch text {
        case "{help}": false
        case "{helpsearch}": true
        default: nil
        }
    }

    /// Whether `text` closes a help block (`{/help}` or `{/helpsearch}`).
    public static func isCloseTag(_ text: String) -> Bool {
        text == "{/help}" || text == "{/helpsearch}"
    }

    private static let relatedPrefix = "Related Helps"
    /// A help topic: alphanumerics with inner spaces, `&`, `-` (e.g. "two
    /// handed", "AT&T"). Mirrors the reference's `%w[%w&%- ]*%w` (plus single
    /// chars). Commas/colons aren't in the class, so they split the list.
    private static let topicRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9]([A-Za-z0-9&\\- ]*[A-Za-z0-9])?"
    )

    /// If `line` is a "Related Helps : a, b, c" line, return it with each topic
    /// marked as a `.sendCommand("help <topic>")` link (styling preserved);
    /// otherwise return it unchanged.
    public static func linkifyRelatedHelps(_ line: Line) -> Line {
        let nsText = line.text as NSString
        let stripped = line.text.trimmingCharacters(in: .whitespaces)
        guard stripped.hasPrefix(relatedPrefix), let topicRegex else { return line }
        // Search only after the colon so the "Related Helps" label isn't linked.
        let colon = nsText.range(of: ":")
        guard colon.location != NSNotFound else { return line }
        let searchStart = colon.location + 1
        guard searchStart < nsText.length else { return line }

        let searchRange = NSRange(location: searchStart, length: nsText.length - searchStart)
        let topicRanges: [Range<Int>] = topicRegex
            .matches(in: line.text, range: searchRange)
            .map { $0.range.lowerBound..<$0.range.upperBound }
            .filter { $0.upperBound > $0.lowerBound }
        guard !topicRanges.isEmpty else { return line }

        // Boundary points: line ends, existing run edges, every topic edge —
        // so styling is preserved and each topic becomes one linked slice.
        var points: Set<Int> = [0, nsText.length]
        for run in line.runs {
            points.insert(run.utf16Range.lowerBound)
            points.insert(run.utf16Range.upperBound)
        }
        for range in topicRanges {
            points.insert(range.lowerBound)
            points.insert(range.upperBound)
        }
        let sorted = points.sorted()

        var runs: [StyledRun] = []
        for index in 0..<(sorted.count - 1) {
            let start = sorted[index], end = sorted[index + 1]
            guard start < end else { continue }
            let style = line.runs.first { $0.utf16Range.contains(start) }?.style ?? .default
            let link = topicRanges.first { $0.contains(start) }.map { range -> LineLink in
                let topic = nsText.substring(with: NSRange(
                    location: range.lowerBound,
                    length: range.upperBound - range.lowerBound
                ))
                return LineLink(action: .sendCommand("help \(topic)"), hint: "help \(topic)")
            }
            if !style.isDefault || link != nil {
                runs.append(StyledRun(utf16Range: start..<end, style: style, link: link))
            }
        }
        return Line(id: line.id, timestamp: line.timestamp, text: line.text, runs: runs)
    }

    /// Build the published article from accumulated body lines: derive a title
    /// from the first non-empty line and linkify any "Related Helps" rows.
    public static func makeArticle(from body: [Line], isSearch: Bool) -> HelpArticle {
        let linked = body.map(linkifyRelatedHelps)
        let title = body.first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?
            .text.trimmingCharacters(in: .whitespaces) ?? (isSearch ? "Help search" : "Help")
        return HelpArticle(title: title, lines: linked, isSearch: isSearch)
    }
}

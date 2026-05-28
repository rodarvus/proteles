import Foundation

/// A captured Aardwolf help article: the styled body lines (with clickable
/// cross-reference links already applied) plus a best-effort title. Published
/// to the Help panel.
public struct HelpArticle: Sendable, Equatable {
    /// Best-effort heading (the help file's keyword(s), else the first body line).
    public var title: String
    /// The help body, one styled ``Line`` per row. "Related Helps" topics and
    /// the "Help Keywords" list carry `.sendCommand("help <topic>")` links.
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
/// (and `{helpsearch}…{/helpsearch}`) tag boundaries, strip the inner
/// `{helpkeywords}`/`{helpbody}` markers, and turn help cross-references +
/// keywords into clickable `help <topic>` links. Independent reimplementation
/// of `aard_ingame_help_window` (Fiendish).
///
/// The real block (verified from a live capture) looks like:
/// ```
/// {help}
/// ----------------------------------------------------------------------------
/// {helpkeywords}Help Keywords : CONSIDER.
/// Help Category : Information.
/// Last Updated  : 2024-11-23 09:00:31.
/// ----------------------------------------------------------------------------
/// {helpbody}
/// …body…
/// {/helpbody}
/// ----------------------------------------------------------------------------
/// {/help}
/// ```
/// `{helpbody}`/`{/helpbody}` are whole-line markers (dropped); `{helpkeywords}`
/// is an inline prefix on the keyword line (stripped, keywords linkified).
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
    private static let keywordsPrefix = "Help Keywords"
    private static let helpKeywordsTag = "{helpkeywords}"
    /// Whole-line markers that exist only to delimit the body; never displayed.
    private static let bodyTags: Set<String> = ["{helpbody}", "{/helpbody}"]

    /// A help topic for "Related Helps": alphanumerics with inner spaces, `&`,
    /// `-` (e.g. "two handed"). Mirrors the reference's `%w[%w&%- ]*%w`.
    private static let topicRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9]([A-Za-z0-9&\\- ]*[A-Za-z0-9])?"
    )

    /// A single keyword token (no inner spaces — keywords are space-separated,
    /// the trailing period excluded).
    private static let keywordRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9][A-Za-z0-9'&\\-]*"
    )

    /// If `line` is a "Related Helps : a, b, c" line, return it with each topic
    /// marked as a `.sendCommand("help <topic>")` link (styling preserved);
    /// otherwise return it unchanged.
    public static func linkifyRelatedHelps(_ line: Line) -> Line {
        guard line.text.trimmingCharacters(in: .whitespaces).hasPrefix(relatedPrefix),
              let topicRegex
        else { return line }
        return buildLinkedLine(line, topicRanges: topicRanges(in: line, using: topicRegex))
    }

    /// If `line` is a "Help Keywords : X Y" line, return it with each keyword
    /// marked as a `help <keyword>` link; otherwise return it unchanged. (The
    /// `{helpkeywords}` prefix is stripped separately, before this runs.)
    public static func linkifyHelpKeywords(_ line: Line) -> Line {
        guard line.text.trimmingCharacters(in: .whitespaces).hasPrefix(keywordsPrefix),
              let keywordRegex
        else { return line }
        return buildLinkedLine(line, topicRanges: topicRanges(in: line, using: keywordRegex))
    }

    /// Build the published article from accumulated body lines: drop the
    /// `{helpbody}` markers, strip the `{helpkeywords}` prefix + linkify its
    /// keywords, linkify "Related Helps", and derive a title.
    public static func makeArticle(from body: [Line], isSearch: Bool) -> HelpArticle {
        var lines: [Line] = []
        for original in body {
            let trimmed = original.text.trimmingCharacters(in: .whitespaces)
            if bodyTags.contains(trimmed) { continue }
            if original.text.contains(helpKeywordsTag) {
                lines.append(linkifyHelpKeywords(stripping(helpKeywordsTag, from: original)))
            } else {
                lines.append(linkifyRelatedHelps(original))
            }
        }
        return HelpArticle(title: title(from: lines, isSearch: isSearch), lines: lines, isSearch: isSearch)
    }

    // MARK: - Private

    /// Topic/keyword ranges found after the first `:` of `line` (so the label
    /// before the colon is never linked).
    private static func topicRanges(in line: Line, using regex: NSRegularExpression) -> [Range<Int>] {
        let nsText = line.text as NSString
        let colon = nsText.range(of: ":")
        guard colon.location != NSNotFound else { return [] }
        let searchStart = colon.location + 1
        guard searchStart < nsText.length else { return [] }
        let searchRange = NSRange(location: searchStart, length: nsText.length - searchStart)
        return regex.matches(in: line.text, range: searchRange)
            .map { $0.range.lowerBound..<$0.range.upperBound }
            .filter { $0.upperBound > $0.lowerBound }
    }

    /// Re-slice `line` so each range in `topicRanges` becomes one
    /// `help <topic>`-linked run, preserving the existing styling.
    private static func buildLinkedLine(_ line: Line, topicRanges: [Range<Int>]) -> Line {
        guard !topicRanges.isEmpty else { return line }
        let nsText = line.text as NSString

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

    /// Remove the first occurrence of `tag` from `line`'s text, shifting run
    /// ranges so styling survives.
    private static func stripping(_ tag: String, from line: Line) -> Line {
        let nsText = line.text as NSString
        let range = nsText.range(of: tag)
        guard range.location != NSNotFound else { return line }
        let cut = range.location
        let length = range.length
        let newText = nsText.replacingCharacters(in: range, with: "")

        func shift(_ point: Int) -> Int {
            point <= cut ? point : max(cut, point - length)
        }
        var runs: [StyledRun] = []
        for run in line.runs {
            let lower = shift(run.utf16Range.lowerBound)
            let upper = shift(run.utf16Range.upperBound)
            if upper > lower {
                runs.append(StyledRun(utf16Range: lower..<upper, style: run.style, link: run.link))
            }
        }
        return Line(id: line.id, timestamp: line.timestamp, text: newText, runs: runs)
    }

    /// Prefer the help file's keyword(s) as the title; else the first
    /// non-empty, non-divider line; else a generic fallback.
    private static func title(from lines: [Line], isSearch: Bool) -> String {
        if let keywords = lines.first(where: {
            $0.text.trimmingCharacters(in: .whitespaces).hasPrefix(keywordsPrefix)
        }) {
            let nsText = keywords.text as NSString
            let colon = nsText.range(of: ":")
            if colon.location != NSNotFound, colon.location + 1 < nsText.length {
                let after = nsText.substring(from: colon.location + 1)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                if !after.isEmpty { return after }
            }
        }
        if let first = lines.first(where: {
            let trimmed = $0.text.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !isDivider(trimmed)
        }) {
            return first.text.trimmingCharacters(in: .whitespaces)
        }
        return isSearch ? "Help search" : "Help"
    }

    /// A horizontal rule (`----…`) the help header uses as a separator.
    private static func isDivider(_ trimmed: String) -> Bool {
        trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
    }
}

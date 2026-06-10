import Foundation

/// Display handling for Aardwolf's telnet-102 tagged output (`{rname}…`,
/// `{coords}…`, `{/roomchars}`, `{spellheaders hsp}` — enabled with the
/// game's `tags … on` config, which plugins like dinv depend on).
///
/// The opt-in "clean tag markers" preference used to withhold the whole
/// line, which threw away real content — with `tags rname on`, the room
/// name *only* arrives as `{rname}The top of the tower`, so gagging the
/// line meant no room names at all (live report, 2026-06-10). The rule now:
/// **strip the marker, keep the content**; hide the line entirely only when
/// nothing displayable remains (a bare `{roomobjs}` marker) or the tag's
/// content is machine data (`{coords}4,6,20`).
///
/// Applied display-only, after every plugin/script has seen the raw line —
/// the caller (`SessionController.appendLineThroughScripts`) guarantees the
/// ordering; this type is pure.
public enum AardwolfTags {
    /// Tags whose content is machine-readable data, not prose — the whole
    /// line hides (showing "4,6,20" or invmon CSV is noise). `{coords}` per
    /// the user's call; the rest are the data tags observed in live
    /// recordings.
    public static let machineDataTags: Set<String> = [
        "coords", "invmon", "invdata", "invitem", "affon", "affoff",
        "skillgain", "sfail", "recon"
    ]

    /// The leading tag marker in `text`, if it starts with one: the tag name
    /// (without `/` or arguments) and the marker's UTF-16 length including
    /// the braces. The grammar matches Aardwolf's tagged output only: `{` at
    /// position 0, optional `/`, an identifier starting with a lowercase
    /// ASCII letter (body: lowercase/digits/`_`), optionally followed by a
    /// space and arguments (`{chan ch=tech}`, `{invdata 123}`), then `}`.
    /// dinv's `{ DINV fence }` (space first, uppercase) never matches.
    static func leadingTag(in text: String) -> (name: String, utf16Length: Int)? {
        var rest = Substring(text)
        guard rest.first == "{" else { return nil }
        var length = 1
        rest = rest.dropFirst()
        if rest.first == "/" {
            length += 1
            rest = rest.dropFirst()
        }
        guard let first = rest.first, ("a"..."z").contains(first) else { return nil }
        var name = String(first)
        length += 1
        rest = rest.dropFirst()
        // Identifier body.
        while let char = rest.first, isIdentifierBody(char) {
            name.append(char)
            length += 1
            rest = rest.dropFirst()
        }
        // Optional ` arguments` up to the closing brace ({chan ch=tech}).
        if rest.first == " " {
            while let char = rest.first, char != "}", char != "{" {
                length += 1
                rest = rest.dropFirst()
            }
        }
        guard rest.first == "}" else { return nil }
        return (name, length + 1) // all marker characters are single UTF-16 units
    }

    private static func isIdentifierBody(_ char: Character) -> Bool {
        ("a"..."z").contains(char) || ("0"..."9").contains(char) || char == "_"
    }

    /// What the main window should display for `line`: the line unchanged
    /// (not a tag line), the line with its leading marker stripped (runs
    /// shifted, styling kept), or nil to hide it — a machine-data tag, or
    /// nothing left but whitespace after the marker.
    public static func displayLine(for line: Line) -> Line? {
        guard let tag = leadingTag(in: line.text) else { return line }
        if machineDataTags.contains(tag.name) { return nil }
        let stripped = line.droppingUTF16Prefix(tag.utf16Length)
        let isBlank = stripped.text.trimmingCharacters(in: .whitespaces).isEmpty
        return isBlank ? nil : stripped
    }
}

public extension Line {
    /// This line with its first `count` UTF-16 units removed — text shortened
    /// and every styled run shifted/clamped (runs that fall entirely inside
    /// the dropped prefix disappear; links survive on what remains).
    func droppingUTF16Prefix(_ count: Int) -> Line {
        guard count > 0 else { return self }
        let nsText = text as NSString
        guard count < nsText.length else {
            return Line(id: id, timestamp: timestamp, text: "", runs: [])
        }
        let shifted = runs.compactMap { run -> StyledRun? in
            let lower = max(run.utf16Range.lowerBound - count, 0)
            let upper = run.utf16Range.upperBound - count
            guard upper > lower else { return nil }
            return StyledRun(utf16Range: lower..<upper, style: run.style, link: run.link)
        }
        return Line(
            id: id,
            timestamp: timestamp,
            text: nsText.substring(from: count),
            runs: shifted
        )
    }
}

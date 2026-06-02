import Foundation

/// Faithful reproduction of the reference Aardwolf mapper's text output
/// (`aardmapper.lua` + `aard_GMCP_mapper.xml`): the mapper note colour, the
/// bordered ASCII tables, and clickable rows. Every `mapper …` command emits
/// through these helpers so output matches MUSHclient — colour, table layout,
/// and click-to-`mapper goto` behaviour.
///
/// **Colour.** The reference's `MAPPER_NOTE_COLOUR`/`ROOM_NOTE_COLOUR` are
/// `ColourNameToRGB "lightgreen"` (#90EE90) and `maperror` is `"red"` (#FF0000).
/// The reference's *table* rows use a plain `Note` (the world note colour), but
/// the Aardwolf world default (`note_text_colour="#040000"`) is effectively
/// invisible, so we render the mapper's whole non-error output in its identity
/// colour, lightgreen — readable, and exactly what the conversational `mapprint`
/// lines use. (If a live MUSHclient check shows tables in a different colour,
/// split table-colour out here — the renderer is centralised for that reason.)
enum MapperOutput {
    /// `mapprint` colour — `ColourNameToRGB "lightgreen"`.
    static let noteColour = "#90EE90"
    /// `maperror` colour — `ColourNameToRGB "red"`.
    static let errorColour = "#FF0000"

    /// A mapper note line (≈ `mapprint`/`Note`), in the mapper colour.
    static func line(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: noteColour)])
    }

    /// A mapper error line (≈ `maperror`), red.
    static func error(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: errorColour)])
    }

    /// A clickable mapper row that speedwalks on click — the native equivalent
    /// of the reference's `Hyperlink("mapper goto <uid>", line, …)`.
    static func gotoRow(_ text: String, uid: String, hint: String? = nil) -> ScriptEffect {
        .colourNote([NoteSegment(
            text: text,
            foreground: noteColour,
            link: LineLink(
                action: .sendCommand("mapper goto \(uid)"),
                hint: hint ?? "Click to speedwalk there"
            )
        )])
    }

    /// MUSHclient `%<w>.<w>s` (or `%-<w>.<w>s` when `leftAlign`): truncate to
    /// `width`, then pad to `width` — right-aligned by default, left when asked.
    static func field(_ value: String, _ width: Int, leftAlign: Bool = false) -> String {
        let truncated = value.count > width ? String(value.prefix(width)) : value
        let padding = String(repeating: " ", count: max(0, width - truncated.count))
        return leftAlign ? truncated + padding : padding + truncated
    }

    /// A `+----+----+` border for the given inner column widths. Each column is
    /// padded by one space on each side (matching the reference's `| %…s |`), so
    /// a width-`w` column contributes `w + 2` dashes.
    static func border(_ widths: [Int]) -> String {
        "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
    }

    /// A `| a | b | c |` row from already-`field`-formatted cells.
    static func row(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }
}

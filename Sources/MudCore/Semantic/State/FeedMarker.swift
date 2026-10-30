import Foundation

/// The opening or closing marker of one of S0b's tag feeds at the start of
/// a line — `{roomchars}`, `{/roomchars}`, `{invdata 123}`, `{exits}` —
/// parsed once per line for the tracker and the collector (S0b item 1, #84).
///
/// Most tag lines (`{rdesc}`, `{coords}`, `{rname}`, …) are not S0b's, so the
/// marker name is read from the UTF-8 bytes first and only one of
/// ``ActionableState/Feed``'s names goes on to the router's full grammar
/// (`AardwolfTags.leadingTag(in:)`), which stays the single authority on
/// what is a tag. The byte read cannot reject a line that grammar accepts
/// with one of these names: there, the name is followed by `}` or a space,
/// where the byte read stops too.
struct FeedMarker: Sendable, Equatable {
    let feed: ActionableState.Feed
    let isClosing: Bool
    /// `hsp` for `{spellheaders hsp}`; empty for closing markers and markers
    /// without arguments.
    let arguments: String

    /// The feed marker `text` starts with, if any.
    static func parse(_ text: String) -> FeedMarker? {
        let utf8 = text.utf8
        var index = utf8.startIndex
        guard index != utf8.endIndex, utf8[index] == UInt8(ascii: "{") else { return nil }
        utf8.formIndex(after: &index)
        let isClosing = index != utf8.endIndex && utf8[index] == UInt8(ascii: "/")
        if isClosing { utf8.formIndex(after: &index) }
        let nameStart = index
        while index != utf8.endIndex, isIdentifierByte(utf8[index]) {
            utf8.formIndex(after: &index)
        }
        guard let feed = ActionableState.Feed(marker: String(text[nameStart..<index])),
              let tag = AardwolfTags.leadingTag(in: text), tag.name == feed.rawValue
        else { return nil }
        return FeedMarker(
            feed: feed,
            isClosing: isClosing,
            arguments: isClosing ? "" : arguments(in: text, after: index)
        )
    }

    /// The text between the marker name and its closing brace, trimmed; the
    /// grammar allows no `}` inside the arguments.
    private static func arguments(in text: String, after nameEnd: String.Index) -> String {
        guard nameEnd != text.utf8.endIndex, text.utf8[nameEnd] == UInt8(ascii: " "),
              let close = text.utf8[nameEnd...].firstIndex(of: UInt8(ascii: "}"))
        else { return "" }
        return text[nameEnd..<close].trimmingCharacters(in: .whitespaces)
    }

    /// `leadingTag`'s identifier bytes: lowercase ASCII letters, digits, `_`.
    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "_")
    }
}

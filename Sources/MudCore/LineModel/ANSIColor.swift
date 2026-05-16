import Foundation

/// A colour as specified by an ANSI SGR sequence.
///
/// The parser preserves the precise form the server emitted; concrete RGB
/// resolution happens in the rendering layer with the user's active palette
/// (PLAN.md §6.6). Treating ``palette(_:)`` indices 0…15 and ``named(_:)`` /
/// ``brightNamed(_:)`` as distinct lets the renderer apply the palette
/// consistently regardless of which SGR form arrived.
public enum ANSIColor: Sendable, Equatable, Hashable {
    /// One of the eight named colours (SGR 30–37, 40–47).
    case named(NamedColor)
    /// A bright variant of a named colour (SGR 90–97, 100–107).
    case brightNamed(NamedColor)
    /// An indexed colour from the 256-colour palette (SGR 38;5;N or 48;5;N).
    case palette(UInt8)
    /// A direct 24-bit RGB colour (SGR 38;2;R;G;B or 48;2;R;G;B).
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

/// The eight named ANSI colours. Raw values match the SGR offset: SGR 30
/// is ``black``, SGR 31 is ``red``, … SGR 37 is ``white``. The renderer
/// resolves these to concrete RGB through the active palette.
public enum NamedColor: UInt8, Sendable, Equatable, Hashable, CaseIterable {
    case black = 0
    case red = 1
    case green = 2
    case yellow = 3
    case blue = 4
    case magenta = 5
    case cyan = 6
    case white = 7
}

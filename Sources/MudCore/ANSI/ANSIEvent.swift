import Foundation

/// One event emitted by ``ANSIParser`` as it consumes a byte stream.
///
/// Text events carry the current ``StyleAttributes`` snapshot at the
/// moment they were emitted, so the consumer never needs its own SGR
/// state.
public enum ANSIEvent: Sendable, Equatable {
    /// A run of plain text under the parser's current style.
    case text(String, StyleAttributes)

    /// Line-feed (0x0A). Marks end-of-line for ``Line`` assembly.
    case lineFeed

    /// Carriage-return (0x0D). Aardwolf emits CRLF; downstream may ignore
    /// bare CR or treat it as "go to start of line".
    case carriageReturn

    /// Bell (0x07). Audible by default, configurable.
    case bell

    /// Backspace (0x08).
    case backspace

    /// Tab (0x09).
    case tab

    /// Any other C0 control byte the parser passed through (NUL, VT, FF,
    /// SO, SI, etc.).
    case otherControl(UInt8)

    /// A CSI sequence other than SGR ('m'). The parser recognises the
    /// shape but does not act on it; consumers may interpret or ignore.
    case unhandledCSI(final: UInt8, parameters: [Int])
}

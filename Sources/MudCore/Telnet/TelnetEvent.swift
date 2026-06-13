import Foundation

/// One event emitted by ``TelnetProcessor``: per data byte (with IAC
/// escaping removed) or per complete telnet sequence.
public enum TelnetEvent: Sendable, Equatable {
    /// A plain data byte from the server. `IAC IAC` is reported as a
    /// single `0xFF` data byte (see ARCHITECTURE.md §5.2).
    case data(UInt8)

    /// A standalone command byte such as NOP, GA, AYT, EC, EL, BRK …
    case command(UInt8)

    /// An option-negotiation pair. `verb` is WILL / WONT / DO / DONT;
    /// `option` is the option code (see ``TelnetOption``).
    case negotiate(verb: TelnetVerb, option: UInt8)

    /// A complete subnegotiation payload. The bracketing `IAC SB` /
    /// `IAC SE` bytes are already consumed; `payload` is the inner bytes
    /// with any `IAC IAC` un-escaped to a single `0xFF`.
    case subnegotiation(option: UInt8, payload: [UInt8])
}

/// One of the four telnet option-negotiation verbs.
public enum TelnetVerb: UInt8, Sendable, Equatable {
    case will = 0xFB
    case wont = 0xFC
    case `do` = 0xFD
    case dont = 0xFE
}

import Foundation

/// Telnet command bytes (RFC 854 + RFC 1184 SE clarification).
///
/// Standalone commands surface as ``TelnetEvent/command(_:)``. The
/// negotiation verbs (``will`` / ``wont`` / ``do`` / ``dont``) surface
/// via ``TelnetEvent/negotiate(verb:option:)``, and SB/SE bracket
/// subnegotiation payloads via
/// ``TelnetEvent/subnegotiation(option:payload:)``.
public enum TelnetCommand {
    public static let iac: UInt8 = 0xFF
    public static let se: UInt8 = 0xF0
    public static let nop: UInt8 = 0xF1
    public static let dm: UInt8 = 0xF2
    public static let brk: UInt8 = 0xF3
    public static let ip: UInt8 = 0xF4
    public static let ao: UInt8 = 0xF5
    public static let ayt: UInt8 = 0xF6
    public static let ec: UInt8 = 0xF7
    public static let el: UInt8 = 0xF8
    public static let ga: UInt8 = 0xF9
    public static let sb: UInt8 = 0xFA
    public static let will: UInt8 = 0xFB
    public static let wont: UInt8 = 0xFC
    public static let `do`: UInt8 = 0xFD
    public static let dont: UInt8 = 0xFE
}

import Foundation

/// Telnet option codes Proteles handles.
///
/// Not exhaustive — only the options we accept, refuse intentionally, or
/// otherwise need to recognise. See PLAN.md §5.2 for the negotiation
/// policy table.
public enum TelnetOption {
    public static let echo: UInt8 = 1
    public static let suppressGoAhead: UInt8 = 3
    public static let status: UInt8 = 5
    public static let terminalType: UInt8 = 24
    public static let endOfRecord: UInt8 = 25
    public static let naws: UInt8 = 31
    public static let terminalSpeed: UInt8 = 32
    public static let lineMode: UInt8 = 34
    public static let environ: UInt8 = 36
    public static let newEnviron: UInt8 = 39
    public static let charset: UInt8 = 42
    public static let msdp: UInt8 = 69
    public static let mssp: UInt8 = 70
    public static let mccp2: UInt8 = 86
    public static let mccp3: UInt8 = 87
    public static let msp: UInt8 = 90
    public static let mxp: UInt8 = 91
    public static let atcp: UInt8 = 200
    public static let gmcp: UInt8 = 201
}

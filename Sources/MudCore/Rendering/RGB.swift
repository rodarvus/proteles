import Foundation

/// Platform-agnostic 8-bit-per-channel RGB triple.
///
/// MudCore stores colours in this form so that resolution from
/// ``ANSIColor`` does not depend on AppKit or UIKit. The
/// platform-specific view layer converts to `NSColor` / `UIColor` at
/// the rendering boundary.
public struct RGB: Sendable, Equatable, Hashable, Codable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex value: UInt32) {
        self.init(
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        )
    }

    public init?(hex string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

import Foundation

/// Platform-agnostic 8-bit-per-channel RGB triple.
///
/// MudCore stores colours in this form so that resolution from
/// ``ANSIColor`` does not depend on AppKit or UIKit. The
/// platform-specific view layer converts to `NSColor` / `UIColor` at
/// the rendering boundary.
public struct RGB: Sendable, Equatable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

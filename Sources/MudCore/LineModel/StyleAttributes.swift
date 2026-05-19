import Foundation

/// Text styling accumulated from ANSI SGR sequences.
///
/// ``foreground`` / ``background`` of `nil` mean "terminal default" — i.e.
/// the active palette's default for that channel. ``reverse`` is a flag
/// rather than a pre-swapped fg/bg pair so the renderer can swap at draw
/// time and the value compares cleanly when SGR-27 unsets it.
public struct StyleAttributes: Sendable, Equatable, Hashable, Codable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var reverse: Bool
    public var strikethrough: Bool

    public init(
        foreground: ANSIColor? = nil,
        background: ANSIColor? = nil,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        reverse: Bool = false,
        strikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.reverse = reverse
        self.strikethrough = strikethrough
    }

    /// The neutral style: no colours, no flags. Equivalent to the state
    /// after SGR 0.
    public static let `default` = StyleAttributes()

    public var isDefault: Bool {
        self == .default
    }
}

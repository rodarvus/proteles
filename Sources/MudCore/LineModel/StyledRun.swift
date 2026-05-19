import Foundation

/// A contiguous span of styled text within a ``Line``.
///
/// ``utf16Range`` is in UTF-16 code units — the same index space used by
/// `NSAttributedString`, `NSRegularExpression`, and AppKit's text view
/// APIs. The renderer can use these ranges directly without conversion.
public struct StyledRun: Sendable, Equatable, Hashable, Codable {
    public let utf16Range: Range<Int>
    public let style: StyleAttributes

    public init(utf16Range: Range<Int>, style: StyleAttributes) {
        self.utf16Range = utf16Range
        self.style = style
    }
}

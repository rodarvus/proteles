#if os(macOS)
    import AppKit
    import MudCore

    public extension NSAttributedString.Key {
        /// Carries the original ``StyleAttributes`` for a styled run.
        ///
        /// Set by ``AttributedStringBuilder``; read by ``SGREncoder`` to
        /// reconstruct an ANSI-coded string on "Copy with Colour Codes".
        /// Without this we'd have to invert `NSColor` → `ANSIColor`, which
        /// is lossy whenever a renderer chose a near-palette match.
        static let protelesStyle = NSAttributedString.Key("com.proteles.style")
    }

    /// `NSCopying`-conforming `NSObject` wrapper around a ``StyleAttributes``
    /// so it can ride inside `NSAttributedString`'s attribute dictionary.
    ///
    /// `NSAttributedString` stores attribute values as `Any`, but everything
    /// it touches needs to survive `NSCopying` (the framework copies
    /// attribute dictionaries on substring operations). Hence the class +
    /// `copy(with:)` rather than dropping a plain `StyleAttributes` in
    /// directly.
    public final class ProtelesStyleAttribute: NSObject, NSCopying {
        public let value: StyleAttributes

        public init(_ value: StyleAttributes) {
            self.value = value
        }

        public func copy(with _: NSZone? = nil) -> Any {
            ProtelesStyleAttribute(value)
        }

        override public func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? ProtelesStyleAttribute else { return false }
            return value == other.value
        }

        override public var hash: Int {
            value.hashValue
        }
    }
#endif

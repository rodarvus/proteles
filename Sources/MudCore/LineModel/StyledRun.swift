import Foundation

/// What a hyperlink does when clicked — the native equivalent of
/// MUSHclient's `Hyperlink(action, …)`: either open a URL in the browser or
/// send a command to the MUD.
public enum LinkAction: Sendable, Equatable, Hashable, Codable {
    case openURL(String)
    case sendCommand(String)
}

/// A clickable hyperlink carried by a ``StyledRun``: an action plus an
/// optional hover hint. Backs the native hyperlink primitive shared by the
/// URL auto-linkifier, native plugins (`proteles.hyperlink`), and the
/// MUSHclient `Hyperlink`/`MakeHyperlink` shim.
public struct LineLink: Sendable, Equatable, Hashable, Codable {
    public let action: LinkAction
    public let hint: String?

    public init(action: LinkAction, hint: String? = nil) {
        self.action = action
        self.hint = hint
    }

    /// Build a link the way MUSHclient `Hyperlink` interprets its action
    /// string: a URL (`http(s)`/`mailto`) opens in the browser, anything else
    /// is sent to the MUD as a command.
    public init(actionString: String, hint: String? = nil) {
        let lowered = actionString.lowercased()
        let isURL = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("mailto:")
        action = isURL ? .openURL(actionString) : .sendCommand(actionString)
        self.hint = hint
    }
}

/// A contiguous span of styled text within a ``Line``.
///
/// ``utf16Range`` is in UTF-16 code units — the same index space used by
/// `NSAttributedString`, `NSRegularExpression`, and AppKit's text view
/// APIs. The renderer can use these ranges directly without conversion.
///
/// An optional ``link`` makes the span a clickable hyperlink.
public struct StyledRun: Sendable, Equatable, Hashable, Codable {
    public let utf16Range: Range<Int>
    public let style: StyleAttributes
    public let link: LineLink?

    public init(utf16Range: Range<Int>, style: StyleAttributes, link: LineLink? = nil) {
        self.utf16Range = utf16Range
        self.style = style
        self.link = link
    }
}

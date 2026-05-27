import Foundation

/// Turns URLs in MUD output into clickable hyperlinks, preserving the line's
/// colour. Independent Swift implementation; the idea is a long-standing MUD
/// staple (e.g. Nick Gammon's `Hyperlink_URL2`).
///
/// A thin `NativePlugin` over the pure ``URLLinkifier``: `onLine` returns a
/// replacement ``Line`` whose URL spans carry `.openURL` links (the macOS
/// renderer makes them clickable; clicking opens the browser). Toggleable and
/// persisted per world like the other native plugins; enabled by default.
public struct URLLinkify: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.urllinkify",
        name: "URL Links",
        author: "Proteles",
        version: "1.0",
        summary: "Turn URLs in the output into clickable links (opens in your browser)."
    )

    public init() {}

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        let linked = URLLinkifier.linkify(line)
        return linked == line ? .init() : .init(replacement: linked)
    }
}

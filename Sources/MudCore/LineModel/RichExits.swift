import Foundation

/// Pure, value-typed logic for the **Rich Exits** feature: detect Aardwolf's
/// tagged exits line and render a replacement whose direction tokens are
/// clickable `.sendCommand` hyperlinks. Independent reimplementation of
/// deathr's `Aardwolf-Rich-Exits` plugin (which uses a MUSHclient miniwindow +
/// `Hyperlink`); here the exits stay in the **main game window** as a rewritten
/// ``Line``, and custom exits come from our native mapper rather than a SQLite
/// read.
///
/// The reference enables `tags exits on` so Aardwolf wraps its exits line in a
/// deterministic `{exits}[ Exits: … ]` form, then *ignores* the captured text
/// and rebuilds the list from GMCP (cardinals) + the mapper (custom exits). We
/// follow the same approach: ``isTaggedExitsLine(_:)`` is just the "show exits
/// now" signal; ``render(cardinals:customExits:id:timestamp:)`` builds the line
/// from the supplied data.
public enum RichExits {
    /// A cardinal exit: its display word, the command to send, and (optionally)
    /// the destination room number for the hover hint.
    public struct Cardinal: Equatable, Sendable {
        public let label: String // "north"
        public let command: String // "north"
        public let destination: Int? // destination room vnum (for the hint)

        public init(label: String, command: String, destination: Int?) {
            self.label = label
            self.command = command
            self.destination = destination
        }
    }

    /// A custom (non-cardinal) exit: the command to run when clicked and the
    /// destination room uid for the hint. Sourced from the mapper graph.
    public struct CustomExit: Equatable, Sendable, Codable {
        public let command: String // "enter portal"
        public let destination: String? // destination room uid (for the hint)

        public init(command: String, destination: String?) {
            self.command = command
            self.destination = destination
        }
    }

    /// Compass directions, in the order Aardwolf's exits line lists them, with
    /// their full-word labels/commands.
    private static let directionOrder: [(key: String, word: String)] = [
        ("n", "north"), ("e", "east"), ("s", "south"), ("w", "west"),
        ("u", "up"), ("d", "down"),
        ("ne", "northeast"), ("nw", "northwest"),
        ("se", "southeast"), ("sw", "southwest")
    ]

    private static let cardinalKeys: Set<String> = Set(directionOrder.map(\.key))

    /// Whether `dir` (an `exits`-table direction) is a compass direction rather
    /// than a custom-exit command string.
    public static func isCardinalDirection(_ dir: String) -> Bool {
        cardinalKeys.contains(dir.lowercased())
    }

    /// Build the ordered cardinal list from a GMCP `room.info.exits` map
    /// (`{ "n": 1234, "e": 5678 }`), skipping invalid `-1` destinations.
    public static func cardinals(fromExits exits: [String: Int]?) -> [Cardinal] {
        guard let exits else { return [] }
        return directionOrder.compactMap { entry in
            guard let dest = exits[entry.key], dest != -1 else { return nil }
            return Cardinal(label: entry.word, command: entry.word, destination: dest)
        }
    }

    // MARK: - Detection

    private static let taggedPrefix = "{exits}[ Exits:"

    /// True for Aardwolf's tagged exits line (`{exits}[ Exits: … ]`), emitted
    /// when `tags exits on` is active. The capture is ignored — it only signals
    /// "render the exits now".
    public static func isTaggedExitsLine(_ text: String) -> Bool {
        text.hasPrefix(taggedPrefix) && text.hasSuffix("]")
    }

    /// True for the one-shot confirmation Aardwolf prints when toggling the
    /// exits tag — gagged so the `tags exits on/off` we send stays invisible.
    public static func isTagConfirmation(_ text: String) -> Bool {
        text == "Tag option exits turned ON" || text == "Tag option exits turned OFF"
    }

    // MARK: - Rendering

    /// Build the clickable replacement line: `[ Exits: <cardinals> <customs> ]`
    /// in green, each direction a `.sendCommand` link with a "moves to …" hint.
    /// Preserves the original line's `id`/`timestamp` so it replaces in place.
    public static func render(
        cardinals: [Cardinal],
        customExits: [CustomExit],
        id: LineID,
        timestamp: Date
    ) -> Line {
        let green = StyleAttributes(foreground: .named(.green))
        var text = ""
        var runs: [StyledRun] = []

        func push(_ segment: String, link: LineLink? = nil) {
            guard !segment.isEmpty else { return }
            let start = (text as NSString).length
            text += segment
            let end = (text as NSString).length
            runs.append(StyledRun(utf16Range: start..<end, style: green, link: link))
        }

        push("[ Exits:")
        var hasAny = false
        for cardinal in cardinals {
            let hint = cardinal.destination.map { "moves to \($0)" }
            push(" ")
            push(cardinal.label, link: LineLink(action: .sendCommand(cardinal.command), hint: hint))
            hasAny = true
        }
        for custom in customExits {
            // Quote multi-word commands so the token reads as one unit.
            let display = custom.command.contains(" ") ? "'\(custom.command)'" : custom.command
            let hint = custom.destination.map { "'\(custom.command)' moves to \($0)" }
            push(" ")
            push(display, link: LineLink(action: .sendCommand(custom.command), hint: hint))
            hasAny = true
        }
        if !hasAny { push(" none") }
        push(" ]")

        return Line(id: id, timestamp: timestamp, text: text, runs: runs)
    }
}

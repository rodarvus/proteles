import Foundation

/// Mobs coming and going between consider runs: the lines the original
/// plugin's `track_mob_moves` group reads (S0b item 2, #84).
///
/// The original lists 19 verbs each way. The recordings have more (swoops
/// 858 times, flutters 396, flits 362, then waddles, stomps, slithers,
/// marches, plods, prowls, sloshes, pads, crawls, sneaks), and other areas
/// have their own, so no verb is listed:
///
/// - **Leaving** is `<name> <verb> <exit>.` (`A radiant ibis flutters
///   south.`). Other lines share the shape (`Your speed slows down.`), so the
///   model acts on one only when the name is a mob on its list.
/// - **Arriving** is `<name> <verb> in from [the] <direction>.`,
///   `<name> arrives from [the] <direction>.` or `<name> appears in the
///   room.` A name the room's description gives as `You see a kobold knight
///   charging in from the west.` becomes `A kobold knight`.
/// - **A thunderclap** (`With a thunderclap, Turnus appears in the room.`)
///   is a player arriving: all 109 such names in the recordings are players.
///   It is ignored, as is any name flagged as a player.
enum ConsiderMovement {
    private static let exits: Set<Substring> = ["north", "south", "east", "west", "up", "down"]
    private static let origins: Set<Substring> = ["north", "south", "east", "west", "above", "below"]
    private static let thunderclap = "With a thunderclap, "
    private static let appears = " appears in the room."
    private static let fledSuffix = " has fled!"
    private static let youSee = "You see "

    /// The name and exit of a line shaped like a departure. The name may be
    /// anyone's: the caller checks it against its list.
    static func departure(_ text: String) -> (name: String, exit: String)? {
        guard text.hasSuffix("."), let space = text.lastIndex(of: " ") else { return nil }
        let exit = text[text.index(after: space)..<text.index(before: text.endIndex)]
        guard exits.contains(exit), let name = dropVerb(text[..<space]) else { return nil }
        return (name, String(exit))
    }

    /// The name of a mob arriving, or nil for any other line.
    static func arrival(_ text: String) -> String? {
        guard text.hasSuffix("."), !text.hasPrefix(thunderclap) else { return nil }
        if text.hasSuffix(appears) { return mobName(text.dropLast(appears.count)) }
        guard let from = text.range(of: " from ", options: .backwards) else { return nil }
        var origin = text[from.upperBound..<text.index(before: text.endIndex)]
        if origin.hasPrefix("the ") { origin = origin.dropFirst(4) }
        guard origins.contains(origin) else { return nil }
        let head = text[..<from.lowerBound]
        if head.hasSuffix(" in") { return dropVerb(head.dropLast(3)) }
        if head.hasSuffix(" arrives") { return mobName(head.dropLast(8)) }
        return nil
    }

    /// The name of whoever fled.
    static func fled(_ text: String) -> String? {
        guard text.hasSuffix(fledSuffix) else { return nil }
        return mobName(text.dropLast(fledSuffix.count))
    }

    /// `head` without its last word, which must be a lowercase verb.
    private static func dropVerb(_ head: Substring) -> String? {
        guard let space = head.lastIndex(of: " ") else { return nil }
        let verb = head[head.index(after: space)...]
        guard !verb.isEmpty, verb.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return nil }
        return mobName(head[..<space])
    }

    /// The name with any aura flags removed; nil for a player or no name.
    private static func mobName(_ text: Substring) -> String? {
        let split = AuraFlags.split(text)
        guard !AuraFlags.isPlayer(split.flags) else { return nil }
        var name = split.rest
        if name.hasPrefix(youSee) {
            name = name.dropFirst(youSee.count)
            guard let first = name.first else { return nil }
            return first.uppercased() + name.dropFirst()
        }
        return name.isEmpty ? nil : String(name)
    }
}

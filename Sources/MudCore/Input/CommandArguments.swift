import Foundation

/// What kind of value a command's argument expects, so completion can draw from
/// the right source (#32). Maps to a list on ``CompletionVocabulary``.
public enum CommandArgumentKind: String, Sendable, Equatable, CaseIterable {
    /// An owned item — inventory/equipment (wear, wield, quaff, sell, …). #32 B.
    case item
    /// A spell name (cast). #32.
    case spell
    /// A room exit / direction (open, close, unlock, …). #32.
    case exit
    /// An S&D area key (runto, xrt). #32 A.
    case area
    /// A player/mob name (handled mostly via directed channels in #31).
    case player
}

/// Per-verb argument grammar for completion (#32). Curated, not parsed from
/// `help <command>` — that's reserved for a future syntax *hint*. Most commands
/// take a single completable first argument, so the table maps a verb to the
/// kind of its first argument; positions beyond the first fall back to the
/// generic context/recent sources.
public enum CommandArguments {
    /// verb → kind of its **first** argument.
    static let firstArgumentKind: [String: CommandArgumentKind] = {
        var map: [String: CommandArgumentKind] = [:]
        // Owned-item verbs (inventory/equipment). `get`/`take` are floor items —
        // those come from room tags in #32 C, not dinv.
        for verb in [
            "drop", "put", "give", "wear", "wield", "hold", "remove",
            "quaff", "eat", "drink", "recite", "use", "junk", "donate", "sell",
            "value", "appraise", "identify", "fill", "empty", "keep", "unkeep",
            "compare", "examine", "sacrifice", "brandish", "zap", "enrune"
        ] {
            map[verb] = .item
        }
        for verb in ["runto", "xrt"] {
            map[verb] = .area
        }
        for verb in ["cast"] {
            map[verb] = .spell
        }
        for verb in ["open", "close", "unlock", "lock", "pick"] {
            map[verb] = .exit
        }
        return map
    }()

    /// The argument kind for `verb` at `argumentIndex` (0 = first argument), or
    /// `nil` to fall back to generic completion. Only the first argument is
    /// classified today; later positions can be added per-verb.
    public static func argumentKind(verb: String, argumentIndex: Int) -> CommandArgumentKind? {
        guard argumentIndex == 0 else { return nil }
        return firstArgumentKind[verb.lowercased()]
    }
}

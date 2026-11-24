import Foundation

/// The aura flags in front of a person or mob — `(P)(F)(W) (OPK) Tinada…`,
/// `(Golden Aura) (Hidden) A thief` — as `help auras` describes them (S0b
/// item 2, #84; `docs/plans/S0B_ITEM2_PROPOSAL.md` §7).
///
/// Flags are kept as text, without their parentheses, in order. Only the
/// player flag is interpreted: `(P)` short, `(Player)` long (`shortflags`
/// picks which). Every other flag stays text: the help doesn't list all of
/// them (`(Linkdead)`, `(Joyful)` and `(HARDCORE)` appear in recordings), so
/// an unknown flag is never a reason to reject a line.
enum AuraFlags {
    /// The leading run of parenthesised flags in `text`, allowing a single
    /// space between groups, and the rest with its leading space removed.
    static func split(_ text: Substring) -> (flags: [String], rest: Substring) {
        var flags: [String] = []
        var index = text.startIndex
        while index < text.endIndex, text[index] == "(" {
            let contentStart = text.index(after: index)
            guard let close = text[contentStart...].firstIndex(of: ")"), close > contentStart,
                  !text[contentStart..<close].contains("(")
            else { break }
            flags.append(String(text[contentStart..<close]))
            index = text.index(after: close)
            // `(W) (OPK)`: one space may separate groups.
            if index < text.endIndex, text[index] == " " {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "(" { index = next }
            }
        }
        var rest = text[index...]
        if !flags.isEmpty, rest.first == " " { rest = rest.dropFirst() }
        return (flags, rest)
    }

    /// Whether `flags` mark a player, never a target.
    static func isPlayer(_ flags: [String]) -> Bool {
        flags.contains("P") || flags.contains("Player")
    }
}

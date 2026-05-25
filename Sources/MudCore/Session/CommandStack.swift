import Foundation

/// Client-side command stacking, the MUSHclient/Aardwolf convention: a typed
/// line is split into separate commands on `;`, and a doubled `;;` is an
/// escaped literal `;` (so it doesn't split). Examples:
///
///   - `n;s;e`          → `["n", "s", "e"]`
///   - `open south;s`   → `["open south", "s"]`
///   - `say hi;;there`  → `["say hi;there"]`  (one command, literal `;`)
///   - `n;;;s`          → `["n;", "s"]`        (`;;` literal, then a split)
///   - `` (empty)       → `[""]`               (preserved → bare-Enter nudge)
///
/// Pure + value-type so the splitting is unit-tested without a session.
public enum CommandStack {
    public static func split(_ input: String, separator: Character = ";") -> [String] {
        var pieces: [String] = []
        var current = ""
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            guard character == separator else {
                current.append(character)
                index = input.index(after: index)
                continue
            }
            let next = input.index(after: index)
            if next < input.endIndex, input[next] == separator {
                current.append(separator) // `;;` → one literal `;`
                index = input.index(after: next)
            } else {
                pieces.append(current) // a real separator → end this command
                current = ""
                index = next
            }
        }
        pieces.append(current)
        return pieces
    }
}

import Foundation

/// Splits a mapper speedwalk / custom-exit command string into an ordered list
/// of *command chunks* and *timed pauses* — a faithful port of the Aardwolf
/// mapper's `ExecuteWithWaits` (aard_GMCP_mapper.xml `ExecuteWithWaits`, called
/// for every `start_speedwalk` in `aardmapper.lua`).
///
/// A custom exit's "direction" is whatever command string the player stored for
/// the hop, and the mapper lets it embed `wait(<seconds>)` tokens that mean
/// "pause the walk here", NOT a command to send. The canonical example (a real
/// row from a live `Aardwolf.db` exits table) is a hunt-walk:
///
///     hunt crystal;wait(1);hunt crystal;wait(1);hunt crystal;wait(1)
///
/// The reference splits on `;?wait(<num>);?`, `Execute`s the command runs
/// between the waits, and turns each `wait(N)` into a real coroutine pause
/// (`wait.time`) gated on a server echo round-trip — so `wait(1)` is NEVER sent
/// to the MUD. Without this split Proteles' `;`-stacking sends `wait(1)` raw,
/// which the MUD rejects ("Unknown command"), and skips the pauses so the walk
/// desynchronises (D-NN). This type is the pure, testable core of the fix; the
/// ``Mapper`` runs the steps with the echo-synchronised pause.
public enum WaitWalk {
    /// One step of a parsed walk command.
    public enum Step: Sendable, Equatable {
        /// A run of commands to execute (may itself contain `;`-stacked
        /// commands — the command surface splits those, mirroring `Execute`).
        case commands(String)
        /// Pause this many seconds before continuing (the `wait(N)` token).
        case wait(seconds: Double)
    }

    /// The reference Lua pattern `;?wait%(%d*.?%d+%);?` — an optional leading
    /// `;`, `wait(`, a number (`\d*\.?\d+`, so `1`, `0.5`, `.5`, `12`, `3.5`),
    /// `)`, and an optional trailing `;`. The number is captured.
    static let pattern = #";?wait\((\d*\.?\d+)\);?"#

    /// Whether `command` contains at least one `wait(N)` token — the cheap
    /// gate the walker uses to decide between a plain `.execute` and the
    /// echo-synchronised pacer.
    public static func containsWait(_ command: String) -> Bool {
        command.range(of: pattern, options: .regularExpression) != nil
    }

    /// Parse `command` into ordered command chunks + waits, exactly as the
    /// reference `ExecuteWithWaits` loop walks it: the substring before each
    /// `wait(N)` match (when non-empty) is a command chunk, the match is a
    /// pause, and the trailing remainder (when non-empty) is a final chunk.
    /// A command with no `wait(N)` returns a single `.commands` step.
    public static func steps(from command: String) -> [Step] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return command.isEmpty ? [] : [.commands(command)]
        }
        var steps: [Step] = []
        let ns = command as NSString
        var cursor = 0
        let whole = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: command, range: whole) {
            // Commands between the cursor and this wait (reference: Execute the
            // text before the match when `strbegin ~= 1`).
            if match.range.location > cursor {
                let chunk = ns.substring(with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                ))
                if !chunk.isEmpty { steps.append(.commands(chunk)) }
            }
            let captured = match.numberOfRanges > 1
                ? Double(ns.substring(with: match.range(at: 1)))
                : nil
            if let seconds = captured {
                steps.append(.wait(seconds: seconds))
            }
            cursor = match.range.location + match.range.length
        }
        // The remainder after the last wait (reference: Execute(partial) — a
        // no-op when empty).
        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty { steps.append(.commands(tail)) }
        }
        return steps
    }
}

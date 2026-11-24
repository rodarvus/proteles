import Foundation

/// The `Right here you see:` section of a `{scan}` block: the current room's
/// short names (S0b item 2, #84). The other sections are adjacent rooms,
/// out of S0b (D-129 (2), #91).
///
/// ```
/// {scan}
/// Right here you see:
///      - (F)(G) A sunrise mallard
/// North from here you see:
///      - (G) A bold eagle
/// {/scan}
/// ```
enum ScanHere {
    static let header = "Right here you see:"

    /// The mobs in the block's `Right here` section, players dropped; `nil`
    /// when the block has no such section (nothing visible here, or a scan
    /// of one direction).
    static func mobs(in lines: [Line]) -> [(name: String, flags: [String])]? {
        var inSection = false
        var found = false
        var mobs: [(name: String, flags: [String])] = []
        for line in lines {
            let text = line.text
            if let first = text.first, !first.isWhitespace {
                inSection = text == header
                found = found || inSection
                continue
            }
            guard inSection else { continue }
            let entry = text.drop(while: \.isWhitespace)
            guard entry.hasPrefix("- ") else { continue }
            let split = AuraFlags.split(entry.dropFirst(2))
            guard !AuraFlags.isPlayer(split.flags), !split.rest.isEmpty else { continue }
            mobs.append((String(split.rest), split.flags))
        }
        return found ? mobs : nil
    }
}

/// Collects the output of whole-room `consider` commands, from whoever sent
/// them: the player, the Consider feature, or S&D's smartscan fallback
/// (S0b item 2, #84; `docs/plans/S0B_ITEM2_PROPOSAL.md` Q2).
///
/// The session opens a window as it sends each such command
/// (``SessionController`` `sendLine`, the one seam every command passes).
/// `consider` has no tags (`consider all tags` is read as a mob name), so
/// the output is delimited by its own shape: lines before the first
/// consider line are skipped (the room's map and description often arrive
/// first), the consider lines are contiguous, and the first other line
/// after them (the prompt, in practice) ends the run. Runs answer sends in
/// order, oldest first.
struct ConsiderWindow: Sendable {
    /// A run's outcome.
    enum Outcome: Sendable, Equatable {
        case none
        /// A complete run; empty for "You see no one here but yourself!".
        case completed([ConsiderLine])
    }

    /// A send waits at most this long for its first consider line, so a
    /// command that got no answer doesn't hold the window open. Each send
    /// keeps its own clock: an unanswered send's clock must not end the
    /// next one's run. There's no line limit: a consider sent during a
    /// speedwalk is answered after the walk's rooms, up to 1,435 lines and
    /// 8 s later in the recordings.
    static let timeLimit: TimeInterval = 20

    static let emptyRoom = "You see no one here but yourself!"
    /// S&D's other `consider_end_empty` line: no consider in a safe room.
    static let safeRoom = "Strange forces prevent violence here."

    /// When each unanswered send went out, oldest first.
    private var sends: [Date] = []
    private var lines: [ConsiderLine] = []

    var isOpen: Bool {
        !sends.isEmpty
    }

    /// A whole-room `consider` was sent.
    mutating func open(at date: Date) {
        sends.append(date)
    }

    /// Whether `command` considers the whole room: `consider` (or any
    /// abbreviation down to `con`), bare or with `all`.
    static func isRoomConsider(_ command: String) -> Bool {
        let words = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let verb = words.first?.lowercased(), verb.count >= 3,
              "consider".hasPrefix(verb) else { return false }
        return words.count == 1 || (words.count == 2 && words[1].lowercased() == "all")
    }

    mutating func ingest(_ text: String, at date: Date) -> Outcome {
        if let line = ConsiderLine.parse(text) {
            lines.append(line)
            return .none
        }
        if !lines.isEmpty { return finish(lines) }
        if text == Self.emptyRoom { return finish([]) }
        if text == Self.safeRoom {
            _ = finish([])
            return .none
        }
        if let oldest = sends.first, date.timeIntervalSince(oldest) > Self.timeLimit {
            sends.removeFirst()
        }
        return .none
    }

    mutating func reset() {
        sends = []
        lines = []
    }

    private mutating func finish(_ run: [ConsiderLine]) -> Outcome {
        if !sends.isEmpty { sends.removeFirst() }
        lines = []
        return .completed(run)
    }
}

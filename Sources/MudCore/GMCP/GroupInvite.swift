import Foundation

/// A pending Aardwolf group invitation — someone asked you to join their group
/// and you haven't accepted or declined yet. Aardwolf delivers invites as
/// **plain text only** (there is no GMCP for them), so we parse the same lines
/// the reference's `aard_group_monitor` watches and surface them in the Group
/// panel + a notification banner. `inviter` is what `group accept <inviter>`
/// targets.
public struct GroupInvite: Sendable, Equatable, Identifiable {
    public let inviter: String
    public let groupName: String

    public var id: String {
        inviter
    }

    public init(inviter: String, groupName: String) {
        self.inviter = inviter
        self.groupName = groupName
    }
}

/// A group-invitation state change parsed from one server line. The patterns are
/// ported **verbatim** from the Aardwolf package's `aard_group_monitor_gmcp.xml`
/// (one add trigger + the family of cancel/decline triggers); Aardwolf sends no
/// GMCP for any of this, so the text is the only signal. Every line that retracts
/// an invite — the inviter cancels, you decline, the group disbands, the inviter
/// leaves the group or the game, or "no invitation outstanding" — maps to
/// ``cancelled`` keyed on the inviter, exactly as the reference's `group_cancel`
/// does (`invitations[wildcards[1]] = nil`).
public enum GroupInviteEvent: Sendable, Equatable {
    case invited(inviter: String, groupName: String)
    case cancelled(inviter: String)

    /// Parse one line into an event, or `nil` if it isn't invite-related. Cheap:
    /// returns immediately unless the line contains "invit" (every pattern
    /// does), so the per-line cost on a speedwalk flood stays near zero.
    public static func parse(_ line: String) -> GroupInviteEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "invit", options: .caseInsensitive) != nil else { return nil }

        if let groups = firstMatch(invitePattern, in: text), groups.count >= 3 {
            return .invited(inviter: groups[1], groupName: groups[2])
        }
        for pattern in cancelPatterns {
            if let groups = firstMatch(pattern, in: text), groups.count >= 2 {
                return .cancelled(inviter: groups[1])
            }
        }
        return nil
    }

    // MARK: - Patterns (verbatim from aard_group_monitor_gmcp.xml)

    private static let invitePattern = #"^(\w+) has invited you to join group: (.*)\.$"#

    private static let cancelPatterns = [
        #"^(\w+) has cancelled your invitation to join group: (.*)\.$"#,
        #"^You have declined the group invitation from (\w+)\.$"#,
        #"^You have no invitation outstanding from (\w+)\.$"#,
        #"^Your group invite from (\w+) is cancelled because the group has been disbanded\.$"#,
        #"^Your group invitation from (\w+) is cancelled because (\w+) has left that group\.$"#,
        #"^Your group invitation from (\w+) is cancelled because (\w+) has left the game\.$"#
    ]

    /// The full match + capture groups for `pattern` (index 0 is the whole
    /// match), or `nil` when it doesn't match. Missing optional groups are "".
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

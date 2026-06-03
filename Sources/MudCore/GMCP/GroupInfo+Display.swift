import Foundation

/// How the group panel orders members (GH #17). Mirrors the reference group
/// monitor's options, trimmed to the ones worth surfacing natively.
public enum GroupMemberSort: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    /// Server/leader order (as received).
    case standard
    /// Most-hurt first, by HP percentage ascending (the reference's
    /// `byPercentDamage` — "who needs heals").
    case mostHurt
    /// On-quest members first, others after (stable within each group).
    case questGrouped

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .standard: "Default order"
        case .mostHurt: "Most hurt"
        case .questGrouped: "Quest first"
        }
    }
}

public extension GroupInfo {
    /// The members to show: optionally drop anyone not in the room, then sort.
    /// Pure (no UI) so it's unit-testable; the panel calls it with the user's
    /// `@AppStorage` prefs.
    func displayMembers(sort: GroupMemberSort = .standard, roomOnly: Bool = false) -> [Member] {
        var list = members ?? []
        if roomOnly {
            // Drop only members explicitly elsewhere (`here == "0"`); an unknown
            // `here` is kept (mirrors the reference's `here == '0'` exclusion).
            list = list.filter { $0.info?.here != "0" }
        }
        switch sort {
        case .standard:
            return list
        case .mostHurt:
            // Stable sort by HP fraction ascending (most hurt first).
            return list.enumerated()
                .sorted { lhs, rhs in
                    let left = lhs.element.info?.hpFraction ?? 1
                    let right = rhs.element.info?.hpFraction ?? 1
                    return left == right ? lhs.offset < rhs.offset : left < right
                }
                .map(\.element)
        case .questGrouped:
            // On-quest members first, preserving original order within each group.
            return list.enumerated()
                .sorted { lhs, rhs in
                    let leftQuest = lhs.element.info?.onQuest ?? false
                    let rightQuest = rhs.element.info?.onQuest ?? false
                    return leftQuest == rightQuest ? lhs.offset < rhs.offset : leftQuest && !rightQuest
                }
                .map(\.element)
        }
    }
}

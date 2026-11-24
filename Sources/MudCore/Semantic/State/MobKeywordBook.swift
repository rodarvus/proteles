import Foundation

/// Every keyword a mob name can resolve to, and where each came from (S0b
/// item 2, #84; `docs/plans/S0B_ITEM2_PROPOSAL.md` Q4). Resolution, first
/// hit wins:
///
/// 1. the **player's override** — Proteles-owned
///    (``MobKeywordOverrideStore``), what an iOS "set keyword" or
///    `conw kw` writes;
/// 2. **S&D's exception** — its `mob_keyword_exceptions` table, read-only
///    (D-129: S&D keeps owning its data);
/// 3. **the `gmkw` guess** (``ConsiderKeyword/heuristic(_:area:)``).
///
/// Both tables are keyed `area → lowercased name`: names match whatever
/// their case.
public struct MobKeywordBook: Sendable, Equatable {
    /// Where a resolved keyword came from, so a surface can show a guess
    /// differently from one the player set.
    public enum Source: String, Sendable, Codable {
        case player, snd, guess
    }

    public struct Resolved: Sendable, Equatable {
        public let keyword: String
        public let source: Source
    }

    /// `area → lowercased name → keyword`, set by the player.
    public private(set) var overrides: [String: [String: String]]
    /// `area → lowercased name → keyword`, from S&D.
    public private(set) var exceptions: [String: [String: String]]

    public init(overrides: [String: [String: String]] = [:], exceptions: [String: [String: String]] = [:]) {
        self.overrides = Self.lowercasingNames(overrides)
        self.exceptions = Self.lowercasingNames(exceptions)
    }

    /// The keyword for `name` in `area`, and its source.
    public func resolve(_ name: String, area: String?) -> Resolved {
        let key = name.lowercased()
        if let area {
            if let keyword = overrides[area]?[key] { return Resolved(keyword: keyword, source: .player) }
            if let keyword = exceptions[area]?[key] { return Resolved(keyword: keyword, source: .snd) }
        }
        return Resolved(keyword: ConsiderKeyword.heuristic(name, area: area), source: .guess)
    }

    /// Set the player's keyword for `name` in `area`; `nil` or blank clears
    /// it. Returns whether anything changed.
    @discardableResult
    public mutating func setOverride(_ keyword: String?, for name: String, area: String) -> Bool {
        let key = name.lowercased()
        let value = keyword?.trimmingCharacters(in: .whitespaces)
        let new = (value?.isEmpty ?? true) ? nil : value
        guard overrides[area]?[key] != new else { return false }
        overrides[area, default: [:]][key] = new
        if overrides[area]?.isEmpty == true { overrides[area] = nil }
        return true
    }

    private static func lowercasingNames(_ table: [String: [String: String]]) -> [String: [String: String]] {
        table.mapValues { names in
            Dictionary(names.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        }
    }
}

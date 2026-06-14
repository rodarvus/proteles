import Foundation
import GRDB

/// Native port of Search-and-Destroy's `gmkw` ("guess mob keyword") — turns a
/// mob's display name into a targeting keyword, the way S&D does. Ported verbatim
/// from `plugins/search-and-destroy/Search_and_Destroy.xml`:
///
/// 1. **Exceptions** — a curated `(area, mob_name) → keyword` override. S&D keeps
///    these in its `SnDdb.db` `mob_keyword_exceptions` table (seeded from a
///    hardcoded list + the user's own additions); we read that table read-only
///    when present.
/// 2. **Heuristic** — lowercase, strip punctuation/possessives, drop the stop
///    words, apply per-area regex fix-ups, then take the **first word + last
///    word**, each truncated to a short prefix. The first/last step is what turns
///    "boat full pirates" → "boat pirat" (dropping the middle word); the short
///    prefix is what makes the guess match (Aardwolf matches typed text as a
///    *prefix* of the mob's real keyword, so "pirates" would miss a "pirate"
///    keyword — "pirat" hits it).
///
/// S&D randomises the prefix length 4–6 for human-like variety; we use a fixed
/// length (``prefixCap``) for deterministic, reproducible targeting.
public enum ConsiderKeyword {
    /// Deterministic stand-in for S&D's random 4–6 prefix (user's choice: 5).
    static let prefixCap = 5

    /// Stop words dropped before guessing (`gmkw_omit`).
    static let omit: Set<String> = ["a", "an", "and", "of", "or", "some", "the"]

    /// One per-area regex fix-up (`gmkw_area_filters`): Lua patterns translated to
    /// ICU. The first filter that changes the string wins.
    struct AreaFilter {
        let pattern: String
        let replacement: String
    }

    /// Per-area fix-ups, keyed by zone — ported from `gmkw_area_filters`.
    static let areaFilters: [String: [AreaFilter]] = [
        "adaldar": [.init(pattern: #"^.*(el)vish ([A-Za-z]*\s?[A-Za-z]+)$"#, replacement: "$1 $2")],
        "bonds": [.init(pattern: #"^(.*[bgry][A-Za-z]+) dragon$"#, replacement: "$1")],
        "citadel": [.init(pattern: #"^([bgjlmsv][A-Za-z]+) ([ap]r[A-Za-z]+[el]) .+$"#, replacement: "$1 $2")],
        "elemental": [
            .init(pattern: #"^([A-Za-z]+)'([A-Za-z]+) ([A-Za-z]+)$"#, replacement: "$1$2 $3"),
            .init(pattern: #"^wandering ([A-Za-z]+)'([A-Za-z]+) ([A-Za-z]+)$"#, replacement: "$1$2 $3")
        ],
        "hatchling": [
            .init(pattern: #"^([A-Za-z]+) dragon (egg)$"#, replacement: "$1 $2"),
            .init(pattern: #"^([A-Za-z]+) dragon (hatchling)$"#, replacement: "$1 $2"),
            .init(pattern: #"^([A-Za-z]+ [A-Za-z]+) dragon whelp$"#, replacement: "$1"),
            .init(pattern: #"^([A-Za-z]+) dragon (whelp)$"#, replacement: "$1 $2")
        ],
        "sirens": [.init(pattern: #"^miss ([A-Za-z']+)\s?([A-Za-z]*).*[A-Za-z]$"#, replacement: "$1 $2")],
        "sohtwo": [
            .init(pattern: #"^(evil) [A-Za-z]+"#, replacement: "$1"),
            .init(pattern: #"^(good) [A-Za-z]+"#, replacement: "$1")
        ],
        "verume": [.init(pattern: #"^lizardman (temple [A-Za-z]+)$"#, replacement: "$1")],
        "wooble": [
            .init(pattern: #"^sea ([A-Za-z]+)$"#, replacement: "$1"),
            .init(pattern: #"^sea ([A-Za-z]+ [A-Za-z]+)$"#, replacement: "$1")
        ]
    ]

    /// Resolve `name` (the mob's display name) in `area` (room zone) to a
    /// targeting keyword: a curated exception if `exceptions` has one, else the
    /// heuristic guess.
    public static func resolve(
        _ name: String, area: String?, exceptions: [String: [String: String]] = [:]
    ) -> String {
        if let area, let override = exceptions[area]?[name] {
            return override
        }
        return heuristic(name, area: area)
    }

    /// The `gmkw` heuristic (no exceptions): clean → omit → area fix-up →
    /// first+last word, each capped to ``prefixCap`` chars.
    public static func heuristic(_ name: String, area: String?) -> String {
        let cleaned = name.lowercased().split(separator: " ").map { cleanWord(String($0)) }
        let kept = cleaned.filter { !$0.isEmpty && !omit.contains($0) }
        var joined = kept.joined(separator: " ")

        if let area, let filters = areaFilters[area] {
            for filter in filters {
                let replaced = joined.replacingOccurrences(
                    of: filter.pattern, with: filter.replacement, options: .regularExpression
                )
                if replaced != joined {
                    joined = replaced
                    break
                }
            }
        }
        joined = joined.replacingOccurrences(of: "-", with: " ")

        let words = joined.split(separator: " ").map(String.init)
        if words.count > 1 {
            return prefix(words[0]) + " " + prefix(words[words.count - 1])
        } else if let only = words.first {
            return prefix(only)
        }
        return name // every word was omitted — fall back to the original (gmkw stage-4)
    }

    /// Per-word cleanup mirroring `gmkw`: drop a punctuation+hyphen pair, commas,
    /// periods, a trailing possessive, and trailing `!`/`?`.
    private static func cleanWord(_ word: String) -> String {
        var value = word
        value = value.replacingOccurrences(of: #"\p{P}-"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: ",", with: "")
        value = value.replacingOccurrences(of: ".", with: "")
        value = value.replacingOccurrences(of: #"'s$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[!?]+$"#, with: "", options: .regularExpression)
        return value
    }

    private static func prefix(_ word: String) -> String {
        String(word.prefix(prefixCap))
    }

    // MARK: - Exceptions DB

    /// The well-known global Search-and-Destroy database, or nil if its directory
    /// can't be resolved. S&D keeps `SnDdb.db` in the shared Databases dir.
    public static func defaultDatabaseURL() -> URL? {
        (try? ProtelesPaths.databasesDirectory())?.appendingPathComponent("SnDdb.db")
    }

    /// Read the entire `mob_keyword_exceptions` table read-only into an
    /// `area → name → keyword` map. Returns `[:]` if the DB or table is absent
    /// (S&D not installed). Mirrors `DinvItemReader`'s one-shot read-only pattern.
    public static func loadExceptions(
        from url: URL, fileManager: FileManager = .default
    ) -> [String: [String: String]] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA busy_timeout = 2000") }
        guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration) else { return [:] }
        let rows = (try? queue.read { db -> [Row] in
            guard try db.tableExists("mob_keyword_exceptions") else { return [] }
            return try Row.fetchAll(
                db,
                sql: "SELECT area_name, mob_name, keyword FROM mob_keyword_exceptions"
            )
        }) ?? []
        var map: [String: [String: String]] = [:]
        for row in rows {
            guard let area: String = row["area_name"], let name: String = row["mob_name"],
                  let keyword: String = row["keyword"] else { continue }
            map[area, default: [:]][name] = keyword
        }
        return map
    }
}

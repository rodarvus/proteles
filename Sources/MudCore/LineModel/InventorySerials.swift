import Foundation

/// Pure logic for the **Inventory Serials** feature: parse Aardwolf's `invdata`
/// / `keyring data` / `vault data` CSV rows, group identical items, and render
/// the grouped list with serial numbers + flag colours + counts. Independent
/// reimplementation of Fiendish's `aard_inventory_serials` (which does the same
/// via a MUSHclient miniwindow-free re-`Simulate`); here the controller/plugin
/// captures the `{invdata}…{/invdata}` block and feeds these rows in.
///
/// Row format (the reference's `invrex`): `id,flags,name,level,…` — eight
/// comma-separated fields; only the first four matter for display. Keyring/vault
/// rows may have leading whitespace.
public enum InventorySerials {
    /// One parsed inventory row.
    public struct Item: Equatable, Sendable {
        public let id: String
        public let flags: String // e.g. "MG" (magic, glowing) — single-char codes
        public let name: String
        public let level: Int

        public init(id: String, flags: String, name: String, level: Int) {
            self.id = id
            self.flags = flags
            self.name = name
            self.level = level
        }
    }

    /// Identical items grouped (same flags + name + level), with their serials.
    public struct Group: Equatable, Sendable {
        public let flags: String
        public let name: String
        public let level: Int
        public let ids: [String]

        public var count: Int {
            ids.count
        }
    }

    /// Item-flag → Aardwolf `@`-colour, mirroring the reference's `color_lookup`
    /// (blue aura, kept, magic, glowing, humming, invis, cursed, …). Unknown
    /// flags render in `@w`.
    private static let flagColour: [Character: String] = [
        "B": "@c", "R": "@R", "K": "@R", "M": "@B", "G": "@W", "H": "@C",
        "I": "@w", "C": "@D", "T": "@R", "E": "@G", "W": "@D"
    ]

    /// A CSV row: id, flags, name, level, then 4 more fields we ignore. Leading
    /// whitespace (keyring/vault) tolerated. `name` may contain spaces but the
    /// server strips commas from names, so a comma always delimits fields.
    private static let rowRegex = try? NSRegularExpression(
        pattern: #"^\s*(\d+),(\w*),(.+),(\d+),(\d+),([01]),(-?\d+),(-?\d+)"#
    )

    /// Parse one CSV row into an ``Item`` (nil if it isn't a data row).
    public static func parseRow(_ text: String) -> Item? {
        guard let rowRegex else { return nil }
        let ns = text as NSString
        guard let match = rowRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 5
        else { return nil }
        func field(_ index: Int) -> String {
            ns.substring(with: match.range(at: index))
        }
        return Item(id: field(1), flags: field(2), name: field(3), level: Int(field(4)) ?? 0)
    }

    /// Group consecutive-or-not identical items (same flags+name+level),
    /// preserving first-seen order and collecting each group's serial ids.
    public static func group(_ items: [Item]) -> [Group] {
        var order: [String] = []
        var firstByKey: [String: Item] = [:] // first-seen item supplies flags/name/level
        var idsByKey: [String: [String]] = [:]
        for item in items {
            let key = "\(item.flags)\u{1}\(item.name)\u{1}\(item.level)"
            if firstByKey[key] == nil {
                firstByKey[key] = item
                order.append(key)
            }
            idsByKey[key, default: []].append(item.id)
        }
        return order.compactMap { key in
            guard let first = firstByKey[key] else { return nil }
            return Group(flags: first.flags, name: first.name, level: first.level, ids: idsByKey[key] ?? [])
        }
    }

    /// Render one group to an Aardwolf `@`-coded line, matching the reference's
    /// layout: a `(N)` count when >1, the flag tokens, the name, the serial(s)
    /// (or `many` when >3), and the level. `serialsColour` colours the brackets
    /// + name suffix (default `@w`).
    public static func renderGroup(_ group: Group, serialsColour: String = "@w") -> String {
        let count = group.count > 1 ? "@W(\(pad2(group.count))) @w" : "     "
        let flagTokens = group.flags.map { char in
            "\(flagColour[char] ?? "@w")(\(char))@w"
        }.joined()
        let serials = group.ids.count < 4 ? group.ids.joined(separator: ",") : "many"
        return "\(count)\(flagTokens) \(group.name)\(serialsColour)  [\(serials)]  @W(@G\(group.level)@W)@w"
    }

    /// Render a whole parsed block (parse → group → lines).
    public static func render(rows: [String], serialsColour: String = "@w") -> [String] {
        group(rows.compactMap(parseRow)).map { renderGroup($0, serialsColour: serialsColour) }
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? " \(value)" : "\(value)"
    }
}

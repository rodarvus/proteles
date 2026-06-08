import Foundation
import GRDB

/// Reads typeable item keywords from a dinv `dinv.db` for `wear`/`wield`/`quaff`/
/// … argument completion (#32 B). The sole dinv-DB access for completion — keep
/// it here, isolated.
///
/// dinv's `items.keywords` mixes its own digit-tagged location tokens
/// (`2020neck`, `T3hold`, `radienceT3`) with the real typeable keywords (plain
/// words: `orb`, `necklace`, `radience`). We split on whitespace and keep the
/// **purely-alphabetic** tokens — verified against the live DB to drop the
/// internal tokens cleanly while keeping the words a player actually types.
public enum DinvItemReader {
    /// Distinct item keywords (lowercased, sorted, ≥ `minLength` letters), or
    /// `[]` if the DB/`items` table is missing. Read-only; one quick query.
    public static func itemKeywords(
        at url: URL,
        minLength: Int = 3,
        fileManager: FileManager = .default
    ) throws -> [String] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA busy_timeout = 2000") }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let fields = try queue.read { db -> [String] in
            guard try db.tableExists("items") else { return [] }
            return try String.fetchAll(db, sql: "SELECT keywords FROM items WHERE keywords IS NOT NULL")
        }
        return keywords(fromFields: fields, minLength: minLength)
    }

    /// The pure extraction (separated for testing): purely-alphabetic,
    /// `minLength`+ tokens across all `fields`, lowercased, deduped, sorted.
    public static func keywords(fromFields fields: [String], minLength: Int = 3) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for field in fields {
            for token in field.split(whereSeparator: \.isWhitespace) {
                let word = token.lowercased()
                guard word.count >= minLength, word.allSatisfy(\.isLetter) else { continue }
                if seen.insert(word).inserted { result.append(word) }
            }
        }
        return result.sorted()
    }
}

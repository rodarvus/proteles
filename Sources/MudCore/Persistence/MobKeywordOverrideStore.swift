import Foundation
import GRDB

/// The player's own mob keywords (S0b item 2, #84; `docs/plans/S0B_ITEM2_PROPOSAL.md`
/// Q4 (a)): the first layer of ``MobKeywordBook``, owned by Proteles rather
/// than written into S&D's `mob_keyword_exceptions` (D-129: S&D keeps owning
/// its data, and S&D may not ship on iOS).
///
/// One small table in the shared Databases folder, so it travels with the
/// rest of the config. Keyed by area and **lowercased** name.
public struct MobKeywordOverrideStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Documents/Proteles/Databases/MobKeywords.db`, or nil if the folder
    /// can't be resolved.
    public static func standard() -> Self? {
        (try? ProtelesPaths.databasesDirectory())
            .map { Self(url: $0.appendingPathComponent("MobKeywords.db")) }
    }

    /// Every override, `area → lowercased name → keyword`; `[:]` when the
    /// file doesn't exist yet or can't be read.
    public func load(fileManager: FileManager = .default) -> [String: [String: String]] {
        guard fileManager.fileExists(atPath: url.path),
              let rows = try? openQueue().read({ db in
                  try Row.fetchAll(db, sql: "SELECT area, name, keyword FROM mob_keyword_overrides")
              })
        else { return [:] }
        var map: [String: [String: String]] = [:]
        for row in rows {
            guard let area: String = row["area"], let name: String = row["name"],
                  let keyword: String = row["keyword"] else { continue }
            map[area, default: [:]][name] = keyword
        }
        return map
    }

    /// Set (or, with `nil`, clear) the keyword for `name` in `area`.
    public func save(_ keyword: String?, for name: String, area: String, at date: Date = Date()) throws {
        try openQueue().write { db in
            if let keyword {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO mob_keyword_overrides (area, name, keyword, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [area, name.lowercased(), keyword, date.timeIntervalSince1970]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM mob_keyword_overrides WHERE area = ? AND name = ?",
                    arguments: [area, name.lowercased()]
                )
            }
        }
    }

    private func openQueue() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA busy_timeout = 2000") }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mob_keyword_overrides (
                area TEXT NOT NULL,
                name TEXT NOT NULL,
                keyword TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (area, name)
            )
            """)
        }
        return queue
    }
}

/// Where ``MobKeywordBook`` is loaded from on connect: the player's
/// overrides and S&D's database (read-only). Either may be absent.
public struct MobKeywordSources: Sendable {
    public var overrides: MobKeywordOverrideStore?
    public var sndDatabase: URL?

    public init(overrides: MobKeywordOverrideStore?, sndDatabase: URL?) {
        self.overrides = overrides
        self.sndDatabase = sndDatabase
    }

    /// The shared Databases folder's `MobKeywords.db` and `SnDdb.db`.
    public static func standard() -> Self {
        Self(overrides: .standard(), sndDatabase: ConsiderKeyword.defaultDatabaseURL())
    }

    public func loadBook() -> MobKeywordBook {
        MobKeywordBook(
            overrides: overrides?.load() ?? [:],
            exceptions: sndDatabase.map { ConsiderKeyword.loadExceptions(from: $0) } ?? [:]
        )
    }
}

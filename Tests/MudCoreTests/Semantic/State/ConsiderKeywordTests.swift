import Foundation
import GRDB
@testable import MudCore
import Testing

@Suite("ConsiderKeyword — gmkw heuristic + exceptions")
struct ConsiderKeywordTests {
    @Test("First+last word, middle dropped, capped to 5 (the boat-pirates case)")
    func firstLastPrefix() {
        // The reported failure: Stripname kept "boat full pirates"; gmkw drops the
        // middle word and prefixes → targets correctly.
        #expect(ConsiderKeyword.heuristic("boat full pirates", area: nil) == "boat pirat")
    }

    @Test("Stop words are omitted before guessing")
    func omitsStopWords() {
        #expect(ConsiderKeyword.heuristic("a boatload of pirates", area: nil) == "boatl pirat")
        #expect(ConsiderKeyword.heuristic("a goblin", area: nil) == "gobli")
    }

    @Test("A single short word stays whole (prefix cap ≥ length)")
    func shortWord() {
        #expect(ConsiderKeyword.heuristic("a rat", area: nil) == "rat")
    }

    @Test("Possessive and trailing punctuation are stripped per word")
    func cleansWords() {
        #expect(ConsiderKeyword.heuristic("the dragon's hoard", area: nil) == "drago hoard")
    }

    @Test("Per-area filters apply (wooble sea-, sohtwo evil/good)")
    func areaFilters() {
        #expect(ConsiderKeyword.heuristic("a sea serpent", area: "wooble") == "serpe")
        #expect(ConsiderKeyword.heuristic("evil dragon", area: "sohtwo") == "evil")
    }

    @Test("Curated exceptions win over the heuristic")
    func exceptionsWin() {
        let table = ["childsplay": ["a young rider": "girl"]]
        #expect(ConsiderKeyword.resolve("a young rider", area: "childsplay", exceptions: table) == "girl")
        // No exception for this area → falls through to the heuristic.
        #expect(ConsiderKeyword
            .resolve("a young rider", area: "elsewhere", exceptions: table) == "young rider")
    }

    /// `consider` capitalises every name ("Best run away from A deputy while
    /// you can!") while S&D stores them as written ("a kobold miner"): in the
    /// recordings, 211 considered names matched an exception only ignoring
    /// case (`docs/plans/S0B_ITEM2_PROPOSAL.md` Q4).
    @Test("An exception matches a name whatever its case (S0b item 2)")
    func exceptionsIgnoreCase() throws {
        let table = ["siege": ["a kobold miner": "miner"]]
        #expect(ConsiderKeyword.resolve("A kobold miner", area: "siege", exceptions: table) == "miner")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("consider-keyword-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("SnDdb.db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE mob_keyword_exceptions (area_name TEXT NOT NULL, mob_name TEXT NOT NULL,
            keyword TEXT NOT NULL, UNIQUE(area_name, mob_name));
            INSERT INTO mob_keyword_exceptions VALUES ('arena', 'a Lizardwoman Peasant', 'lizardwoman');
            """)
        }
        let loaded = ConsiderKeyword.loadExceptions(from: url)
        #expect(ConsiderKeyword
            .resolve("A lizardwoman peasant", area: "arena", exceptions: loaded) == "lizardwoman")
    }

    @Test("Missing database yields an empty exception map (S&D not installed)")
    func missingDatabase() {
        let url = URL(fileURLWithPath: "/nonexistent/SnDdb.db")
        #expect(ConsiderKeyword.loadExceptions(from: url).isEmpty)
    }
}

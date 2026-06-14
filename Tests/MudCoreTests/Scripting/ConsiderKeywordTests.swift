import Foundation
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

    @Test("Missing database yields an empty exception map (S&D not installed)")
    func missingDatabase() {
        let url = URL(fileURLWithPath: "/nonexistent/SnDdb.db")
        #expect(ConsiderKeyword.loadExceptions(from: url).isEmpty)
    }
}

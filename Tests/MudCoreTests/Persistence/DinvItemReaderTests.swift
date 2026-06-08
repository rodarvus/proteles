@testable import MudCore
import Testing

@Suite("DinvItemReader — keyword extraction (#32 B)")
struct DinvItemReaderTests {
    @Test("keeps purely-alphabetic keywords, drops dinv's digit-tagged tokens")
    func extracts() {
        let fields = [
            "T3hold 231hold orb radienceT3", // → orb (tagged tokens dropped)
            "2020neck 230neck necklace radience", // → necklace, radience
            "ab x" // too short / 1-char dropped
        ]
        #expect(DinvItemReader.keywords(fromFields: fields) == ["necklace", "orb", "radience"])
    }

    @Test("empty input → empty")
    func empty() {
        #expect(DinvItemReader.keywords(fromFields: []).isEmpty)
    }
}

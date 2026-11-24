import Foundation
@testable import MudCore
import Testing

/// The player-override → S&D → guess chain (S0b item 2, #84, Q4).
@Suite("MobKeywordBook")
struct MobKeywordBookTests {
    @Test("the player's override wins, then S&D's exception, then the guess")
    func order() {
        var book = MobKeywordBook(exceptions: ["siege": ["a kobold miner": "miner"]])
        #expect(book.resolve("A kobold miner", area: "siege") == .init(keyword: "miner", source: .snd))
        #expect(book.resolve("A kobold miner", area: "aylor") == .init(
            keyword: "kobol miner",
            source: .guess
        ))
        #expect(book.resolve("A kobold miner", area: nil).source == .guess)
        book.setOverride("kobold", for: "A Kobold Miner", area: "siege")
        #expect(book.resolve("a kobold miner", area: "siege") == .init(keyword: "kobold", source: .player))
    }

    @Test("clearing an override falls back; a no-op reports no change")
    func clear() {
        var book = MobKeywordBook(overrides: ["siege": ["A kobold miner": "kobold"]])
        #expect(book.resolve("a kobold miner", area: "siege").source == .player)
        let unchanged = book.setOverride("kobold", for: "a kobold miner", area: "siege")
        #expect(!unchanged)
        let cleared = book.setOverride("  ", for: "a kobold miner", area: "siege")
        #expect(cleared)
        #expect(book.resolve("a kobold miner", area: "siege").source == .guess)
        #expect(book.overrides.isEmpty)
    }

    @Test("the store round-trips overrides through its own database")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mob-keywords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobKeywordOverrideStore(url: directory.appendingPathComponent("MobKeywords.db"))
        #expect(store.load().isEmpty)
        try store.save("villager", for: "A male villager", area: "radiance")
        try store.save("miner", for: "a kobold miner", area: "siege")
        #expect(store.load() == [
            "radiance": ["a male villager": "villager"],
            "siege": ["a kobold miner": "miner"]
        ])
        try store.save(nil, for: "A KOBOLD MINER", area: "siege")
        #expect(store.load() == ["radiance": ["a male villager": "villager"]])
    }
}

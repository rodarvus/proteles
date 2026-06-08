@testable import MudCore
import Testing

@Suite("AardwolfSpells — bundled spell list (#32)")
struct AardwolfSpellsTests {
    @Test("loads the spell list, lowercased + sorted, with multi-word names")
    func loadsList() {
        let all = AardwolfSpells.all
        #expect(all.count > 500)
        #expect(all.contains("fireball"))
        #expect(all.contains("acid blast"))
        #expect(all.contains("word of recall"))
        #expect(all.allSatisfy { $0 == $0.lowercased() })
        #expect(all == all.sorted())
    }
}

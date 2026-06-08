@testable import MudCore
import Testing

@Suite("AardwolfCommands — bundled command list (#31)")
struct AardwolfCommandsTests {
    @Test("loads the full Aardwolf command list, lowercased + sorted")
    func loadsList() {
        let all = AardwolfCommands.all
        #expect(all.count == 519)
        #expect(all.contains("kill"))
        #expect(all.contains("gquest"))
        #expect(all.contains("clantalk"))
        #expect(all.contains("speedwalks"))
        #expect(all.allSatisfy { $0 == $0.lowercased() })
        #expect(all == all.sorted())
    }
}

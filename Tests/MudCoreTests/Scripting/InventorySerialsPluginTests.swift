import Foundation
@testable import MudCore
import Testing

@Suite("InventorySerialsPlugin — intercept + capture + re-render")
struct InventorySerialsPluginTests {
    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    @Test("`inventory` (and abbreviations) is consumed + requests invdata")
    func intercepts() {
        var plugin = InventorySerialsPlugin()
        #expect(plugin.handleCommand("inventory") == [.sendNoEcho("invdata")])
        #expect(plugin.handleCommand("i") == [.sendNoEcho("invdata")])
        #expect(plugin.handleCommand("inv") == [.sendNoEcho("invdata")])
        // Unrelated commands pass through.
        #expect(plugin.handleCommand("look") == nil)
        #expect(plugin.handleCommand("inventory bag") == nil) // args → plain command
    }

    @Test("The {invdata} block is gagged and re-rendered on the closing tag")
    func capturesAndRenders() {
        var plugin = InventorySerialsPlugin()
        _ = plugin.handleCommand("inventory")

        #expect(plugin.onLine(line("{invdata}")).gag) // open marker swallowed
        #expect(plugin.onLine(line("1,M,a potion,10,0,0,0,0")).gag) // rows gagged
        #expect(plugin.onLine(line("2,M,a potion,10,0,0,0,0")).gag)
        let close = plugin.onLine(line("{/invdata}"))
        #expect(close.gag) // closing marker swallowed
        // The re-render is emitted as echo effects: a header + one grouped line.
        let echoes = close.effects.compactMap { effect -> String? in
            if case .echoAard(let text) = effect { return text } else { return nil }
        }
        #expect(echoes.first == "@wYou are carrying:")
        #expect(echoes.contains { $0.contains("a potion") && $0.contains("[1,2]") })
    }

    @Test("Lines are untouched when no inventory command is in flight")
    func passthroughWhenIdle() {
        var plugin = InventorySerialsPlugin()
        let result = plugin.onLine(line("A goblin attacks you!"))
        #expect(!result.gag)
        #expect(result.effects.isEmpty)
    }
}

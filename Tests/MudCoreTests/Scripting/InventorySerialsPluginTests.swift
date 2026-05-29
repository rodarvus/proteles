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

    @Test("keyring list / vault list request their data form and capture their tags")
    func keyringAndVault() {
        var plugin = InventorySerialsPlugin()
        #expect(plugin.handleCommand("keyring list") == [.sendNoEcho("keyring data")])
        #expect(plugin.onLine(line("{keyring}")).gag)
        #expect(plugin.onLine(line("9,K,a brass key,1,0,0,0,0")).gag)
        let close = plugin.onLine(line("{/keyring}"))
        let echoes = close.effects.compactMap { effect -> String? in
            if case .echoAard(let text) = effect { return text } else { return nil }
        }
        #expect(echoes.first == "@C** Items on Keyring **@w")
        #expect(echoes.contains { $0.contains("a brass key") })

        // vault uses its own command + tags.
        #expect(plugin.handleCommand("vault list") == [.sendNoEcho("vault data")])
        #expect(plugin.onLine(line("{vault}")).gag)
        #expect(plugin.onLine(line("{/vault}")).effects.contains { effect in
            if case .echoAard(let text) = effect { return text == "@C** Vault **@w" }
            return false
        })
    }

    @Test("color command sets + persists the serial colour, and re-render uses it")
    func colourCommand() {
        var plugin = InventorySerialsPlugin()
        let effects = plugin.handleCommand("inventory serials color @R")
        #expect(effects?.contains { effect in
            if case .persistPluginState = effect { true } else { false }
        } == true)

        // It survives a persist/restore round-trip…
        let data = try? #require(plugin.persistentState)
        var restored = InventorySerialsPlugin()
        if let data { restored.restore(from: data) }
        // …and the chosen colour reaches the rendered serial brackets.
        _ = restored.handleCommand("inventory")
        _ = restored.onLine(line("{invdata}"))
        _ = restored.onLine(line("1,M,a wand,10,0,0,0,0"))
        let close = restored.onLine(line("{/invdata}"))
        let rendered = close.effects.compactMap { effect -> String? in
            if case .echoAard(let text) = effect { return text } else { return nil }
        }
        #expect(rendered.contains { $0.contains("@R") })
    }
}

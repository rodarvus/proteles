import Foundation
@testable import MudCore
import Testing

@Suite("AardGMCPHandler — sendgmcp command + config synthesis")
struct AardGMCPHandlerTests {
    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    // MARK: - sendgmcp command

    @Test("`sendgmcp <payload>` sends the payload as a GMCP packet")
    func sendGmcpCommand() {
        let plugin = AardGMCPHandler()
        #expect(plugin.handleCommand("sendgmcp config prompt") == [.sendGMCP("config prompt")])
        #expect(plugin.handleCommand("sendgmcp request quest") == [.sendGMCP("request quest")])
        // Multi-word payloads (e.g. dinv's "config prompt off") stay intact.
        #expect(plugin.handleCommand("sendgmcp config prompt off") == [.sendGMCP("config prompt off")])
    }

    @Test("The verb is case-insensitive; payload casing is preserved")
    func verbCaseInsensitivePayloadPreserved() {
        let plugin = AardGMCPHandler()
        // GMCP package names are case-sensitive (Core.Hello), so the payload
        // must not be lowercased.
        #expect(plugin.handleCommand("SendGMCP Core.Hello {}") == [.sendGMCP("Core.Hello {}")])
    }

    @Test("Non-sendgmcp input (and a bare `sendgmcp`) passes through")
    func passthrough() {
        let plugin = AardGMCPHandler()
        #expect(plugin.handleCommand("look") == nil)
        #expect(plugin.handleCommand("sendgmcps now") == nil) // not the verb
        #expect(plugin.handleCommand("sendgmcp") == nil) // no payload → not the alias
        #expect(plugin.handleCommand("sendgmcp   ") == nil) // whitespace-only payload
    }

    // MARK: - config-state synthesis

    @Test("Prompt toggle feedback synthesizes a config GMCP")
    func promptSynthesis() {
        let plugin = AardGMCPHandler()
        let on = plugin.onLine(line("You will now see prompts."))
        #expect(on.effects == [.injectGMCP(package: "config", json: #"{"prompt":"YES"}"#)])
        #expect(!on.gag) // the line stays visible (reference triggers don't omit)

        let off = plugin.onLine(line("You will no longer see prompts."))
        #expect(off.effects == [.injectGMCP(package: "config", json: #"{"prompt":"NO"}"#)])
    }

    @Test("Compact-mode feedback synthesizes a config GMCP")
    func compactSynthesis() {
        let plugin = AardGMCPHandler()
        #expect(plugin.onLine(line("Compact mode set.")).effects
            == [.injectGMCP(package: "config", json: #"{"compact":"YES"}"#)])
        #expect(plugin.onLine(line("Compact mode removed.")).effects
            == [.injectGMCP(package: "config", json: #"{"compact":"NO"}"#)])
    }

    @Test("Unrelated lines produce no effects and aren't gagged")
    func unrelatedLines() {
        let plugin = AardGMCPHandler()
        let disp = plugin.onLine(line("You will now see prompts. (and more)"))
        #expect(disp.effects.isEmpty)
        #expect(!disp.gag)
        #expect(plugin.onLine(line("A goblin attacks you.")).effects.isEmpty)
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclientPluginLoader — XML parsing")
struct MUSHclientPluginLoaderTests {
    /// Mirrors aard_prompt_fixer's real shape: one regexp send-to-script
    /// trigger plus a CDATA script.
    private let promptFixer = """
    <?xml version="1.0" encoding="iso-8859-1"?>
    <!DOCTYPE muclient>
    <muclient>
    <plugin name="Aardwolf_Prompt_Fixer" author="Fiendish"
       id="1b55534e1fa021cf093aaa6d" language="Lua" version="1.0"
       requires="4.73" save_state="y" sequence="-10000"
       purpose="Fixes prompt at startup"/>
    <triggers>
    <trigger enabled="y" regexp="y" match="^(Battle p|P)rompt set to:? (.*)$"
       sequence="100" send_to="12">
    <send>request_prompt()</send>
    </trigger>
    </triggers>
    <script><![CDATA[
    function request_prompt() Send_GMCP_Packet("request prompt") end
    ]]></script>
    </muclient>
    """

    @Test("Plugin metadata is parsed")
    func metadata() throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptFixer)
        #expect(plugin.id == "1b55534e1fa021cf093aaa6d")
        #expect(plugin.name == "Aardwolf_Prompt_Fixer")
        #expect(plugin.author == "Fiendish")
        #expect(plugin.version == "1.0")
        #expect(plugin.savesState)
        #expect(plugin.sequence == -10000)
        #expect(plugin.script.contains("Send_GMCP_Packet"))
    }

    @Test("A regexp send-to-script trigger maps faithfully")
    func scriptTrigger() throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptFixer)
        #expect(plugin.triggers.count == 1)
        let trigger = try #require(plugin.triggers.first)
        #expect(trigger.pattern == .regex("^(Battle p|P)rompt set to:? (.*)$"))
        #expect(trigger.sequence == 100)
        #expect(trigger.enabled)
        #expect(trigger.caseSensitive) // no ignore_case → MUSHclient default
        #expect(!trigger.continueEvaluation) // no keep_evaluating → stop
        #expect(!trigger.gag)
        #expect(trigger.script == "request_prompt()") // send_to=12 → script
        #expect(trigger.sendText == nil)
    }

    @Test("A `script` function attribute generates a MUSHclient-style call")
    func scriptAttribute() throws {
        let xml = """
        <muclient><plugin id="x" name="X"/>
        <triggers>
        <trigger name="OnTell" regexp="y" match="(.+) tells you '(.*)'"
           script="HandleTell" sequence="50"/>
        </triggers></muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let trigger = try #require(plugin.triggers.first)
        #expect(trigger.name == "OnTell")
        #expect(trigger.script == #"HandleTell("OnTell", matches[0], matches)"#)
        #expect(trigger.sequence == 50)
    }

    @Test("Wildcard, ignore_case, keep_evaluating, omit_from_output, group map")
    func attributeMapping() throws {
        let xml = """
        <muclient><plugin id="x" name="X"/>
        <triggers>
        <trigger match="You see *" ignore_case="y" keep_evaluating="y"
           omit_from_output="y" group="spam" send_to="0"><send>look</send></trigger>
        </triggers></muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let trigger = try #require(plugin.triggers.first)
        #expect(trigger.pattern == .wildcard("You see *")) // no regexp
        #expect(!trigger.caseSensitive) // ignore_case=y
        #expect(trigger.continueEvaluation) // keep_evaluating=y
        #expect(trigger.gag) // omit_from_output=y
        #expect(trigger.group == "spam")
        #expect(trigger.sendText == "look") // send_to=0 → world
        #expect(trigger.script == nil)
    }

    @Test("Aliases and timers are parsed")
    func aliasesAndTimers() throws {
        let xml = """
        <muclient><plugin id="x" name="X"/>
        <aliases>
        <alias name="gg" match="gg *" send_to="12"><send>get %1 corpse</send></alias>
        </aliases>
        <timers>
        <timer enabled="y" second="1.00" send_to="12"><send>DoTick()</send></timer>
        </timers></muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let alias = try #require(plugin.aliases.first)
        #expect(alias.name == "gg")
        #expect(alias.pattern == .wildcard("gg *"))
        #expect(alias.sendTo == .script) // send_to=12
        #expect(alias.sendText == "get %1 corpse")

        let timer = try #require(plugin.timers.first)
        #expect(timer.schedule == .every(1.0))
        #expect(timer.action == .script("DoTick()"))
    }

    @Test("Malformed XML throws")
    func malformed() {
        #expect(throws: MUSHclientPluginLoader.ParseError.self) {
            try MUSHclientPluginLoader.parse(xml: "<muclient><plugin id='x'")
        }
    }

    @Test("XML with no <plugin> throws missingPlugin")
    func missingPlugin() {
        #expect(throws: MUSHclientPluginLoader.ParseError.missingPlugin) {
            try MUSHclientPluginLoader.parse(xml: "<muclient></muclient>")
        }
    }
}

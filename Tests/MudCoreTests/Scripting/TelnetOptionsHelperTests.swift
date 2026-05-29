import Foundation
@testable import MudCore
import Testing

@Suite("telnet_options bundled helper")
struct TelnetOptionsHelperTests {
    /// A plugin that `dofile`s telnet_options.lua from its own dir (the standard
    /// Aardwolf idiom) — the file isn't there, so the dofile basename fallback
    /// must resolve our bundled clean-room helper — then enables the spellup tag.
    @Test("dofile(GetInfo(60)..\"telnet_options.lua\") + TelnetOptionOn emits option-102")
    func telnetOptionResolvesAndEmits() async throws {
        let xml = """
        <muclient><plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="TOpt"/>
        <script><![CDATA[
        dofile(GetInfo(60) .. "telnet_options.lua")
        TelnetOptionOn(TELOPT_SPELLUP)
        ]]></script>
        </muclient>
        """
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let context = PluginContext(
            pluginID: plugin.id,
            pluginName: plugin.name,
            pluginDirectory: "/tmp/proteles-topt-\(UUID().uuidString)/", // no telnet_options.lua here
            worldDirectory: "/tmp/",
            appDirectory: "/tmp/"
        )
        let effects = await engine.loadPlugin(plugin, context: context)

        let sentSpellup = effects.contains {
            if case .aardwolfTelnet(let option, let on) = $0 { return option == 7 && on }
            return false
        }
        let cannotOpen = effects.contains {
            if case .note(let text, _, _) = $0 { return text.lowercased().contains("cannot open") }
            return false
        }
        #expect(!cannotOpen, "telnet_options.lua failed to resolve from the bundled helper: \(effects)")
        #expect(sentSpellup, "TelnetOptionOn(TELOPT_SPELLUP) should emit option-102 for option 7: \(effects)")
    }
}

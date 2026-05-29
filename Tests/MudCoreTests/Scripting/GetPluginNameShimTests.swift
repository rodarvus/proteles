import Foundation
@testable import MudCore
import Testing

@Suite("Shim — GetPluginName")
struct GetPluginNameShimTests {
    @Test("GetPluginName() returns the current plugin's name in OnPluginInstall")
    func returnsCurrentPluginName() async throws {
        let xml = """
        <muclient><plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="Spellups"/>
        <script><![CDATA[
        function OnPluginInstall() Note("NAME=" .. GetPluginName()) end
        ]]></script>
        </muclient>
        """
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let effects = await engine.loadPlugin(plugin)
        let texts = effects.compactMap { effect -> String? in
            if case .note(let text, _, _) = effect { return text }
            if case .echo(let text) = effect { return text }
            return nil
        }
        #expect(texts.contains { $0.contains("NAME=Spellups") }, "got \(texts)")
        #expect(!texts.contains { $0.lowercased().contains("attempt to call global 'getpluginname'") })
    }
}

import Foundation
@testable import MudCore
import Testing

@Suite("ScriptEngine — plugin host")
struct PluginHostTests {
    /// A self-contained plugin (no require/dofile/helper libs) exercising the
    /// host scaffolding: a trigger whose body runs in the shim, plus an
    /// OnPluginInstall callback that uses Note + SetVariable.
    private let echoPlugin = """
    <muclient>
    <plugin id="com.test.echo" name="Echo Test" save_state="y"/>
    <triggers>
    <trigger match="ping" send_to="12"><send>Send("pong")</send></trigger>
    </triggers>
    <script><![CDATA[
    function OnPluginInstall()
      SetVariable("loaded", "yes")
      Note("Echo Test installed")
    end
    ]]></script>
    </muclient>
    """

    @Test("Loading a plugin runs its script and OnPluginInstall")
    func loadRunsInstall() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: echoPlugin)
        let engine = try ScriptEngine()
        let effects = await engine.loadPlugin(plugin)

        // OnPluginInstall's Note surfaced as a local echo.
        #expect(effects.contains(.echo("Echo Test installed")))
        // And SetVariable wrote into the plugin's own scope.
        let scopes = await engine.variablesSnapshot()
        #expect(scopes["com.test.echo"]?["loaded"] == "yes")
    }

    @Test("A registered plugin trigger fires in the plugin's context")
    func registeredTriggerFires() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: echoPlugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)
        #expect(await engine.triggerList.count == 1)

        let disposition = await engine.process(line: "ping")
        #expect(disposition.effects == [.send("pong")])
    }

    @Test("A missing OnPluginInstall is a no-op, not an error")
    func missingCallbackIsNoOp() async throws {
        let xml = """
        <muclient><plugin id="com.test.q" name="Q"/>
        <script><![CDATA[ x = 1 ]]></script></muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let engine = try ScriptEngine()
        let effects = await engine.loadPlugin(plugin)
        #expect(effects.isEmpty)
    }
}

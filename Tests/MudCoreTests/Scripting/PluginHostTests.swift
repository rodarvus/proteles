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

    @Test("The `world` global proxies field access to the world API (world.Note(...))")
    func worldGlobalProxies() async throws {
        // Some MUSHclient plugins call the API as fields on the global `world`
        // object (`world.Note(...)` ≡ `Note(...)`). Without a `world` shim that
        // indexes nil and errors ("attempt to index global 'world'").
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.test.world" name="World Test"/>
        <script><![CDATA[
        function OnPluginInstall()
          world.Note("via world: " .. tostring(world.GetPluginID() == GetPluginID()))
        end
        ]]></script>
        </muclient>
        """)
        let engine = try ScriptEngine()
        let effects = await engine.loadPlugin(plugin)
        // world.Note routed to Note (→ echo); world.GetPluginID matched GetPluginID.
        #expect(effects.contains(.echo("via world: true")))
        #expect(!effects.contains { effect in
            if case .echo(let text) = effect { return text.contains("attempt to index") }
            if case .note(let text, _, _) = effect { return text.contains("attempt to index") }
            return false
        })
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

    /// A plugin that registers a *dynamic* trigger whose action is a raw
    /// `response` body with `%1` placeholders and an empty `script` arg + a
    /// script send-to — the exact shape dinv uses for its data/fence triggers.
    /// Exercises AddTriggerEx routing the `response` (not the empty `script`)
    /// and the fire-time `%`-expansion of the captures.
    private let responsePlugin = """
    <muclient>
    <plugin id="com.test.resp" name="Resp Test"/>
    <script><![CDATA[
    function OnPluginInstall()
      AddTriggerEx("val", "^val (.*)$", 'Send("v=%1")',
                   trigger_flag.Enabled + trigger_flag.RegularExpression,
                   custom_colour.Custom11, 0, "", "", sendto.script, 0)
    end
    ]]></script>
    </muclient>
    """

    @Test("AddTriggerEx response body runs as Lua with %1 expanded to captures")
    func dynamicResponseTriggerExpandsWildcards() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: responsePlugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)
        #expect(await engine.triggerList.count == 1)

        let disposition = await engine.process(line: "val 99")
        #expect(disposition.effects == [.send("v=99")])
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

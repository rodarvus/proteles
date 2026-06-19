import Foundation
@testable import MudCore
import Testing

@Suite("ScriptEngine — plugin unload/reload")
struct PluginReloadTests {
    /// A plugin with one static trigger plus an `OnPluginInstall` that registers
    /// a *dynamic* trigger (AddTriggerEx). The dynamic registration is the
    /// reload leak-risk: if unload doesn't clear owned automations, a reload
    /// doubles them.
    private let plugin = """
    <muclient>
    <plugin id="com.test.reload" name="Reload Test" save_state="y"/>
    <triggers>
    <trigger name="static" match="ping" send_to="12"><send>Send("pong")</send></trigger>
    </triggers>
    <script><![CDATA[
    function dyn() Send("dynamic") end
    function OnPluginInstall()
      -- flags = Enabled (1) + RegularExpression (32).
      AddTriggerEx("dyn", "^poke$", "", 33, -1, "", "", "dyn", 12, 100)
    end
    ]]></script>
    </muclient>
    """

    private let handlerPlugin = """
    <muclient>
    <plugin id="com.test.handlers" name="Handler Test" save_state="y"/>
    <script><![CDATA[
    function fire()
      proteles.raiseEvent("reload-event", "event")
      proteles.broadcast("broadcast")
      local value = proteles.call("reload-export")
      if value ~= nil then Send("export:" .. tostring(value)) end
    end
    function OnPluginInstall()
      proteles.onEvent("reload-event", function(text) Send("event:" .. text) end)
      proteles.onBroadcast(function(text) Send("broadcast:" .. text) end)
      proteles.export("reload-export", function() return "owned" end)
      AddTriggerEx("fire", "^fire$", "", 33, -1, "", "", "fire", 12, 100)
    end
    ]]></script>
    </muclient>
    """

    private let callerPlugin = """
    <muclient>
    <plugin id="com.test.caller" name="Caller Test" save_state="y"/>
    <script><![CDATA[
    function call_export()
      local value = proteles.call("reload-export")
      if value ~= nil then Send("export:" .. tostring(value)) end
    end
    function OnPluginInstall()
      AddTriggerEx("call-export", "^call-export$", "", 33, -1, "", "", "call_export", 12, 100)
    end
    ]]></script>
    </muclient>
    """

    @Test("Unloading a plugin removes its static and dynamic automations")
    func unloadClearsOwnedAutomations() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: plugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)
        // Static (XML) + dynamic (OnPluginInstall AddTriggerEx) = 2.
        #expect(await engine.triggerList.count == 2)
        #expect(await engine.process(line: "ping").effects == [.send("pong")])

        await engine.unloadPlugin("com.test.reload")
        #expect(await engine.triggerList.isEmpty)
        // Neither trigger fires once unloaded.
        #expect(await engine.process(line: "ping").effects.isEmpty)
        #expect(await engine.process(line: "poke").effects.isEmpty)
    }

    @Test("Reload is idempotent — registration counts stay stable, no doubling")
    func reloadIsIdempotent() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: plugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)
        #expect(await engine.triggerList.count == 2)

        // One full unload + reload cycle (what ReloadPlugin drives).
        await engine.unloadPlugin("com.test.reload")
        await engine.loadPlugin(parsed)
        #expect(await engine.triggerList.count == 2)

        // A second cycle must not accumulate stale registrations.
        await engine.unloadPlugin("com.test.reload")
        await engine.loadPlugin(parsed)
        #expect(await engine.triggerList.count == 2)

        // Both the static and the reinstalled dynamic trigger still fire once.
        #expect(await engine.process(line: "ping").effects == [.send("pong")])
        #expect(await engine.process(line: "poke").effects == [.send("dynamic")])
    }

    @Test("Reload clears owned event and broadcast handlers")
    func reloadClearsOwnedHandlers() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: handlerPlugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)

        let expected: [ScriptEffect] = [
            .send("event:event"),
            .send("broadcast:broadcast"),
            .send("export:owned")
        ]
        #expect(await engine.process(line: "fire").effects == expected)

        await engine.unloadPlugin("com.test.handlers")
        await engine.loadPlugin(parsed)

        #expect(await engine.process(line: "fire").effects == expected)
    }

    @Test("Unload removes exported plugin functions")
    func unloadClearsOwnedExports() async throws {
        let handler = try MUSHclientPluginLoader.parse(xml: handlerPlugin)
        let caller = try MUSHclientPluginLoader.parse(xml: callerPlugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(handler)
        await engine.unloadPlugin("com.test.handlers")
        await engine.loadPlugin(caller)

        #expect(await engine.process(line: "call-export").effects.isEmpty)
    }

    @Test("isNativePlugin distinguishes native ids from MUSHclient plugin ids")
    func nativePluginDetection() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: plugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)
        #expect(await engine.isNativePlugin(id: "com.test.reload") == false)
        #expect(await engine.isNativePlugin(id: "com.proteles.ticktimer") == false)
    }
}

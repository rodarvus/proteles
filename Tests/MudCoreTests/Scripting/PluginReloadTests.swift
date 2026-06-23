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

    private let lifecyclePlugin = """
    <muclient>
    <plugin id="com.test.lifecycle" name="Lifecycle Test" save_state="y"/>
    <script><![CDATA[
    function OnPluginListChanged()
      Send("list:" .. GetPluginID())
    end
    function OnPluginDisable()
      Send("disable:" .. GetPluginID())
    end
    ]]></script>
    </muclient>
    """

    private let lifecyclePeerPlugin = """
    <muclient>
    <plugin id="com.test.lifecycle.peer" name="Lifecycle Peer" save_state="y"/>
    <script><![CDATA[
    function OnPluginListChanged()
      Send("list:" .. GetPluginID())
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

    @Test("Unload fires OnPluginDisable before clearing the plugin environment")
    func unloadFiresDisableCallback() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: lifecyclePlugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)

        #expect(await engine.unloadPlugin("com.test.lifecycle") == [
            .send("disable:com.test.lifecycle")
        ])
    }

    @Test("Unload falls back to OnPluginClose when no disable callback exists")
    func unloadFiresCloseFallback() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.test.close" name="Close Test"/>
        <script><![CDATA[
        function OnPluginClose() Send("close:" .. GetPluginID()) end
        ]]></script></muclient>
        """)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)

        #expect(await engine.unloadPlugin("com.test.close") == [
            .send("close:com.test.close")
        ])
    }

    @Test("EnablePlugin(true) fires OnPluginEnable on a loaded shim plugin")
    func enablePluginFiresEnableCallback() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.test.enable" name="Enable Test"/>
        <script><![CDATA[
        function OnPluginEnable() Send("enable:" .. GetPluginID()) end
        ]]></script></muclient>
        """)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)

        #expect(await engine.enablePlugin("com.test.enable") == [
            .send("enable:com.test.enable")
        ])
    }

    @Test("Disconnect fires save, disconnect, and close lifecycle callbacks")
    func disconnectFiresCloseCallback() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.test.disconnect" name="Disconnect Test"/>
        <script><![CDATA[
        function OnPluginSaveState() Send("save") end
        function OnPluginDisconnect() Send("disconnect") end
        function OnPluginClose() Send("close") end
        ]]></script></muclient>
        """)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)

        #expect(await engine.disconnectPlugins() == [
            .send("save"),
            .send("disconnect"),
            .send("close")
        ])
    }

    @Test("Plugin list changed fires once across the settled loaded plugin list")
    func pluginListChangedBroadcastsToLoadedPlugins() async throws {
        let first = try MUSHclientPluginLoader.parse(xml: lifecyclePlugin)
        let second = try MUSHclientPluginLoader.parse(xml: lifecyclePeerPlugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(first)
        await engine.loadPlugin(second)

        #expect(await engine.pluginListChanged() == [
            .send("list:com.test.lifecycle"),
            .send("list:com.test.lifecycle.peer")
        ])

        await engine.unloadPlugin("com.test.lifecycle")
        #expect(await engine.pluginListChanged() == [
            .send("list:com.test.lifecycle.peer")
        ])
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

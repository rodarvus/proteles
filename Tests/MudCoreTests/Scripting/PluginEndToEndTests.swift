import Foundation
@testable import MudCore
import Testing

/// End-to-end exercise of the whole compat stack: parse a MUSHclient plugin,
/// load it (script + require + lifecycle), then drive GMCP and connect
/// callbacks and observe the effects — the way the live session does.
@Suite("ScriptEngine — plugin end-to-end")
struct PluginEndToEndTests {
    /// A prompt-fixer-shaped plugin: requires gmcphelper, reacts to the
    /// synthesised GMCP-handler broadcast, reads a GMCP value, and sends a
    /// GMCP packet — the exact mechanisms aard_prompt_fixer uses.
    private let promptish = """
    <muclient>
    <plugin id="com.test.promptish" name="Promptish" save_state="y"/>
    <script><![CDATA[
    require "gmcphelper"
    function OnPluginConnect()
      proteles.echo("connected as " .. tostring(IsConnected()))
    end
    function OnPluginBroadcast(msg, id, name, text)
      if id == "3e7dedbe37e44942dd46d264" and text == "char.status" then
        if gmcp("char.status.state") == "3" then
          Send_GMCP_Packet("request prompt")
        end
      end
    end
    ]]></script>
    </muclient>
    """

    @Test("A GMCP update drives the plugin's OnPluginBroadcast end-to-end")
    func gmcpDrivesBroadcast() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptish)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)

        // State 3 (standing) → the plugin requests the prompt.
        let effects = await engine.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(effects.contains(.sendGMCP("request prompt")))
    }

    @Test("The broadcast is gated on the GMCP value (state != 3 → no send)")
    func broadcastGatedOnValue() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptish)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)

        let effects = await engine.applyGMCP(package: "char.status", json: #"{"state":8}"#)
        #expect(!effects.contains(.sendGMCP("request prompt")))
    }

    @Test("connectPlugins fires OnPluginConnect with live connection state")
    func connectLifecycle() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptish)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)
        await engine.setConnected(true)

        let effects = await engine.connectPlugins()
        #expect(effects == [.echo("connected as true")])
    }

    @Test("No broadcast is synthesised when no plugin is loaded")
    func noBroadcastWithoutPlugins() async throws {
        let engine = try ScriptEngine()
        // Native gmcp projection still happens; no OnPluginBroadcast call.
        let effects = await engine.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(effects.isEmpty)
    }
}
